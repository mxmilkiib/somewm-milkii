/*
 * wlr-brightnessd - brightness and color temperature daemon for wlroots
 *
 * Combines wlsunset's color temperature control with software brightness
 * dimming via the wlr-gamma-control-unstable-v1 protocol. Replaces wlsunset.
 *
 * Color temperature algorithm ported from wlsunset (MIT-licensed, by
 * Kenny Levinsen). Brightness is applied as a linear multiplier on top
 * of the whitepoint-adjusted gamma ramp.
 *
 * Socket protocol (line-based, one command per connection):
 *   "set_brightness <pct>"          - set software brightness on all outputs (1-100)
 *   "set_brightness <name> <pct>"   - set software brightness on one named output
 *   "get_brightness"                - reply: "<pct>" (global default)
 *   "set_temp <kelvin>"      - override temperature (0 = auto)
 *   "get_temp"               - reply: "<kelvin>"
 *   "quit"                   - exit, restoring original gamma
 *
 * Usage: wlr-brightnessd [OPTIONS]
 *   -T <temp>      high (day) temperature (default: 6500)
 *   -t <temp>      low (night) temperature (default: 3500)
 *   -l <lat>       latitude for automatic sun calculation
 *   -L <long>      longitude for automatic sun calculation
 *   -S <sunrise>   manual sunrise time HH:MM
 *   -s <sunset>    manual sunset time HH:MM
 *   -d <duration>  transition duration in seconds (default: 1800)
 *   -g <gamma>     gamma value (default: 1.0)
 *   -o <output>    only control named output (repeatable)
 *   --socket <path>  socket path (default: /tmp/wlr-brightnessd-$UID.sock)
 */

#define _GNU_SOURCE
#define _USE_MATH_DEFINES
#define _XOPEN_SOURCE 700
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <time.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/select.h>
#include <sys/mman.h>
#include <stdint.h>
#include <stdbool.h>
#include <wayland-client.h>
#include "wlr-gamma-control-client-protocol.h"

#define MAX_OUTPUTS 16
#define MAX_NAME 256
#define DEGREES(rad) ((rad) * 180.0 / M_PI)
#define RADIANS(deg) ((deg) * M_PI / 180.0)


// MARK: COLOR TEMPERATURE

struct rgb { double r, g, b; };
struct xyz { double x, y, z; };

static int days_in_year(int year) {
    int leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
    return leap ? 366 : 365;
}

static double date_orbit_angle(struct tm *tm) {
    return 2 * M_PI / (double)days_in_year(tm->tm_year + 1900) * tm->tm_yday;
}

static double equation_of_time(double orbit_angle) {
    return 4 * (0.000075 +
        0.001868 * cos(orbit_angle) -
        0.032077 * sin(orbit_angle) -
        0.014615 * cos(2*orbit_angle) -
        0.040849 * sin(2*orbit_angle));
}

static double sun_declination(double orbit_angle) {
    return 0.006918 -
        0.399912 * cos(orbit_angle) +
        0.070257 * sin(orbit_angle) -
        0.006758 * cos(2*orbit_angle) +
        0.000907 * sin(2*orbit_angle) -
        0.002697 * cos(3*orbit_angle) +
        0.00148 * sin(3*orbit_angle);
}

static double sun_hour_angle(double latitude, double declination, double target_sun) {
    return acos(cos(target_sun) /
        cos(latitude) * cos(declination) -
        tan(latitude) * tan(declination));
}

static time_t hour_angle_to_time(double hour_angle, double eqtime) {
    return DEGREES((4.0 * M_PI - 4 * hour_angle - eqtime) * 60);
}

static int illuminant_d(int temp, double *x, double *y) {
    if (temp >= 2500 && temp <= 7000) {
        *x = 0.244063 + 0.09911e3 / temp + 2.9678e6 / pow(temp, 2) - 4.6070e9 / pow(temp, 3);
    } else if (temp > 7000 && temp <= 25000) {
        *x = 0.237040 + 0.24748e3 / temp + 1.9018e6 / pow(temp, 2) - 2.0064e9 / pow(temp, 3);
    } else {
        return -1;
    }
    *y = (-3 * pow(*x, 2)) + (2.870 * (*x)) - 0.275;
    return 0;
}

static int planckian_locus(int temp, double *x, double *y) {
    if (temp >= 1667 && temp <= 4000) {
        *x = -0.2661239e9 / pow(temp, 3) - 0.2343589e6 / pow(temp, 2) + 0.8776956e3 / temp + 0.179910;
        if (temp <= 2222) {
            *y = -1.1064814 * pow(*x, 3) - 1.34811020 * pow(*x, 2) + 2.18555832 * (*x) - 0.20219683;
        } else {
            *y = -0.9549476 * pow(*x, 3) - 1.37418593 * pow(*x, 2) + 2.09137015 * (*x) - 0.16748867;
        }
    } else if (temp > 4000 && temp < 25000) {
        *x = -3.0258469e9 / pow(temp, 3) + 2.1070379e6 / pow(temp, 2) + 0.2226347e3 / temp + 0.240390;
        *y = 3.0817580 * pow(*x, 3) - 5.87338670 * pow(*x, 2) + 3.75112997 * (*x) - 0.37001483;
    } else {
        return -1;
    }
    return 0;
}

static double clamp01(double value) {
    if (value > 1.0) return 1.0;
    if (value < 0.0) return 0.0;
    return value;
}

static struct rgb xyz_to_rgb(const struct xyz *xyz) {
    return (struct rgb) {
        .r = pow(clamp01(3.2404542 * xyz->x - 1.5371385 * xyz->y - 0.4985314 * xyz->z), 1.0 / 2.2),
        .g = pow(clamp01(-0.9692660 * xyz->x + 1.8760108 * xyz->y + 0.0415560 * xyz->z), 1.0 / 2.2),
        .b = pow(clamp01(0.0556434 * xyz->x - 0.2040259 * xyz->y + 1.0572252 * xyz->z), 1.0 / 2.2)
    };
}

static void rgb_normalize(struct rgb *rgb) {
    double maxw = fmax(rgb->r, fmax(rgb->g, rgb->b));
    rgb->r /= maxw;
    rgb->g /= maxw;
    rgb->b /= maxw;
}

static struct rgb calc_whitepoint(int temp) {
    if (temp == 6500)
        return (struct rgb) {.r = 1.0, .g = 1.0, .b = 1.0};

    struct xyz wp;
    if (temp >= 25000) {
        illuminant_d(25000, &wp.x, &wp.y);
    } else if (temp >= 4000) {
        illuminant_d(temp, &wp.x, &wp.y);
    } else if (temp >= 2500) {
        double x1, y1, x2, y2;
        illuminant_d(temp, &x1, &y1);
        planckian_locus(temp, &x2, &y2);
        double factor = (4000. - temp) / 1500.;
        double sinefactor = (cos(M_PI*factor) + 1.0) / 2.0;
        wp.x = x1 * sinefactor + x2 * (1.0 - sinefactor);
        wp.y = y1 * sinefactor + y2 * (1.0 - sinefactor);
    } else {
        planckian_locus(temp >= 1667 ? temp : 1667, &wp.x, &wp.y);
    }
    wp.z = 1.0 - wp.x - wp.y;

    struct rgb wp_rgb = xyz_to_rgb(&wp);
    rgb_normalize(&wp_rgb);
    return wp_rgb;
}


// MARK: SUN POSITION

struct sun { time_t dawn, sunrise, sunset, night; };

static time_t get_timezone(void) {
    struct tm tm;
    time_t now = time(NULL);
    localtime_r(&now, &tm);
    return tm.tm_gmtoff;
}

static time_t round_day_offset(time_t now, time_t offset) {
    return now - ((now - offset) % 86400);
}

static time_t tomorrow(time_t now, time_t offset) {
    return round_day_offset(now, offset) + 86400;
}

static time_t longitude_time_offset(double longitude) {
    return -longitude * 43200 / M_PI;
}

static int max_int(int a, int b) { return a > b ? a : b; }

static double interpolate_position(time_t now, time_t start, time_t stop) {
    if (start == stop) return stop;
    double pos = (double)(now - start) / (double)(stop - start);
    if (pos > 1.0) pos = 1.0;
    if (pos < 0.0) pos = 0.0;
    return pos;
}


// MARK: CONTEXT

struct output {
    struct wl_output *wl_output;
    char name[MAX_NAME];
    struct zwlr_gamma_control_v1 *control;
    uint32_t gamma_size;
    bool failed;
    bool ready;
    bool no_brightness; /* temp-only: brightness handled by hardware backlight */
    int brightness;     /* per-output software brightness (1-100); ignored when no_brightness */
    time_t retry_at;     /* when to retry creating gamma control (0 = no retry) */
};

static struct {
    struct wl_display *display;
    struct wl_registry *registry;
    struct zwlr_gamma_control_manager_v1 *gamma_manager;

    struct output outputs[MAX_OUTPUTS];
    int noutputs;

    char *filter_names[MAX_OUTPUTS];
    int nfilters;
    char *no_brightness_names[MAX_OUTPUTS];
    int n_no_brightness;

    /* brightness */
    int brightness; /* 1-100 */

    /* temperature config */
    int high_temp;
    int low_temp;
    double gamma;
    double latitude;
    double longitude;
    bool has_location;
    bool manual_time;
    time_t sunrise_sec;
    time_t sunset_sec;
    time_t duration;
    int forced_temp; /* 0 = auto, >0 = fixed */

    /* sun state */
    struct sun sun;
    time_t calc_day;
    time_t longitude_time_offset;

    /* socket */
    int sock_fd;
    char sock_path[256];

    /* timer */
    timer_t timer;
    bool timer_fired;
    int signal_pipe[2];
} ctx;


// MARK: TEMPERATURE CALCULATION

static void recalc_stops(time_t now) {
    time_t day = round_day_offset(now, ctx.longitude_time_offset);
    if (day == ctx.calc_day)
        return;
    ctx.calc_day = day;

    if (ctx.manual_time) {
        ctx.sun.dawn = ctx.sunrise_sec - ctx.duration + day;
        ctx.sun.sunrise = ctx.sunrise_sec + day;
        ctx.sun.sunset = ctx.sunset_sec + day;
        ctx.sun.night = ctx.sunset_sec + ctx.duration + day;
        return;
    }

    if (!ctx.has_location)
        return;

    struct tm tm = {0};
    gmtime_r(&day, &tm);
    double orbit_angle = date_orbit_angle(&tm);
    double decl = sun_declination(orbit_angle);
    double eqtime = equation_of_time(orbit_angle);

    double elev_twilight = RADIANS(90.833 - (-6.0));
    double elev_daylight = RADIANS(90.833 - 3.0);

    double ha_twilight = sun_hour_angle(ctx.latitude, decl, elev_twilight);
    double ha_daylight = sun_hour_angle(ctx.latitude, decl, elev_daylight);

    if (isnan(ha_twilight) || isnan(ha_daylight))
        return;

    ctx.sun.dawn = hour_angle_to_time(fabs(ha_twilight), eqtime) + day;
    ctx.sun.night = hour_angle_to_time(-fabs(ha_twilight), eqtime) + day;
    ctx.sun.sunrise = hour_angle_to_time(fabs(ha_daylight), eqtime) + day;
    ctx.sun.sunset = hour_angle_to_time(-fabs(ha_daylight), eqtime) + day;
}

static double get_position(time_t now) {
    if (ctx.forced_temp > 0)
        return 1.0; /* forced temp handled separately */

    if (!ctx.has_location && !ctx.manual_time)
        return 1.0; /* no location: always day (matches wlsunset default) */

    if (now < ctx.sun.dawn) return 0.0;
    if (now < ctx.sun.sunrise) return interpolate_position(now, ctx.sun.dawn, ctx.sun.sunrise);
    if (now < ctx.sun.sunset) return 1.0;
    if (now < ctx.sun.night) return interpolate_position(now, ctx.sun.night, ctx.sun.sunset);
    return 0.0;
}

static int get_temp(void) {
    if (ctx.forced_temp > 0)
        return ctx.forced_temp;
    double pos = get_position(time(NULL));
    return ctx.low_temp + (double)(ctx.high_temp - ctx.low_temp) * pos;
}

static time_t get_deadline(time_t now) {
    if (ctx.forced_temp > 0)
        return tomorrow(now, ctx.longitude_time_offset);
    if (!ctx.has_location && !ctx.manual_time)
        return tomorrow(now, ctx.longitude_time_offset);
    if (now < ctx.sun.dawn) return ctx.sun.dawn;
    if (now < ctx.sun.sunrise) return now + max_int(1, (ctx.sun.sunrise - ctx.sun.dawn) * 10 / (ctx.high_temp - ctx.low_temp));
    if (now < ctx.sun.sunset) return ctx.sun.sunset;
    if (now < ctx.sun.night) return now + max_int(1, (ctx.sun.night - ctx.sun.sunset) * 10 / (ctx.high_temp - ctx.low_temp));
    return tomorrow(now, ctx.longitude_time_offset);
}

static void update_timer(time_t now) {
    time_t deadline = get_deadline(now);
    if (deadline <= now)
        deadline = now + 60;
    struct itimerspec ts = {
        .it_interval = {0},
        .it_value = {.tv_sec = deadline, .tv_nsec = 0}
    };
    timer_settime(ctx.timer, TIMER_ABSTIME, &ts, NULL);
}


// MARK: GAMMA APPLICATION

static void fill_gamma_table(uint16_t *table, uint32_t ramp_size,
    double rw, double gw, double bw, double gamma, double brightness) {
    uint16_t *r = table;
    uint16_t *g = table + ramp_size;
    uint16_t *b = table + 2 * ramp_size;
    for (uint32_t i = 0; i < ramp_size; i++) {
        double val = (double)i / (ramp_size - 1);
        r[i] = (uint16_t)(UINT16_MAX * pow(val * rw, 1.0 / gamma) * brightness);
        g[i] = (uint16_t)(UINT16_MAX * pow(val * gw, 1.0 / gamma) * brightness);
        b[i] = (uint16_t)(UINT16_MAX * pow(val * bw, 1.0 / gamma) * brightness);
    }
}

static bool apply_gamma(struct output *o) {
    if (o->failed || !o->ready || o->gamma_size == 0)
        return false;

    size_t table_size = 3 * o->gamma_size * sizeof(uint16_t);
    int fd = memfd_create("wlr-brightnessd-gamma", MFD_CLOEXEC);
    if (fd < 0) { perror("memfd_create"); return false; }
    if (ftruncate(fd, table_size) < 0) { perror("ftruncate"); close(fd); return false; }
    uint16_t *table = mmap(NULL, table_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (table == MAP_FAILED) { perror("mmap"); close(fd); return false; }

    int temp = get_temp();
    struct rgb wp = calc_whitepoint(temp);
    double brightness = o->no_brightness ? 1.0 : (o->brightness / 100.0);
    fill_gamma_table(table, o->gamma_size, wp.r, wp.g, wp.b, ctx.gamma, brightness);

    munmap(table, table_size);
    zwlr_gamma_control_v1_set_gamma(o->control, fd);
    close(fd);
    return true;
}

static void apply_all_gamma(void) {
    for (int i = 0; i < ctx.noutputs; i++) {
        struct output *o = &ctx.outputs[i];
        if (o->control && !o->failed)
            apply_gamma(o);
    }
    wl_display_flush(ctx.display);
}

/* retry creating gamma controls for outputs that previously failed */
static const struct zwlr_gamma_control_v1_listener gamma_listener;
static void retry_failed_controls(void) {
    time_t now = time(NULL);
    for (int i = 0; i < ctx.noutputs; i++) {
        struct output *o = &ctx.outputs[i];
        if (o->failed && o->retry_at > 0 && now >= o->retry_at) {
            o->retry_at = 0;
            o->failed = false;
            o->control = zwlr_gamma_control_manager_v1_get_gamma_control(
                ctx.gamma_manager, o->wl_output);
            zwlr_gamma_control_v1_add_listener(o->control, &gamma_listener, o);
            fprintf(stderr, "wlr-brightnessd: retrying gamma control for %s\n", o->name);
        }
    }
    wl_display_roundtrip(ctx.display);
    /* apply gamma to any newly-recovered outputs */
    for (int i = 0; i < ctx.noutputs; i++) {
        struct output *o = &ctx.outputs[i];
        if (o->control && !o->failed && o->ready)
            apply_gamma(o);
    }
    wl_display_flush(ctx.display);
}


// MARK: WAYLAND

static void gamma_size_cb(void *data, struct zwlr_gamma_control_v1 *ctrl, uint32_t size) {
    struct output *o = data;
    o->gamma_size = size;
    o->ready = true;
}

static void gamma_failed_cb(void *data, struct zwlr_gamma_control_v1 *ctrl) {
    struct output *o = data;
    o->failed = true;
    o->ready = false;
    /* per protocol: destroy the failed control, then retry after a delay */
    zwlr_gamma_control_v1_destroy(o->control);
    o->control = NULL;
    o->retry_at = time(NULL) + 3;
    fprintf(stderr, "wlr-brightnessd: gamma control failed for %s, will retry in 3s\n", o->name);
}

static const struct zwlr_gamma_control_v1_listener gamma_listener = {
    .gamma_size = gamma_size_cb,
    .failed = gamma_failed_cb,
};

static void wl_output_name_cb(void *data, struct wl_output *wl_output, const char *name) {
    struct output *o = data;
    if (name) snprintf(o->name, sizeof(o->name), "%s", name);
}

/* stubs for unused wl_output events */
static void wl_output_geometry(void *d, struct wl_output *o, int32_t a, int32_t b, int32_t c, int32_t e, int32_t f, const char *g, const char *h, int32_t i) {}
static void wl_output_mode(void *d, struct wl_output *o, uint32_t a, int32_t b, int32_t c, int32_t d2) {}
static void wl_output_done(void *d, struct wl_output *o) {}
static void wl_output_scale_cb(void *d, struct wl_output *o, int32_t f) {}
static void wl_output_description_cb(void *d, struct wl_output *o, const char *desc) {}

static const struct wl_output_listener output_listener = {
    .geometry = wl_output_geometry,
    .mode = wl_output_mode,
    .done = wl_output_done,
    .scale = wl_output_scale_cb,
    .name = wl_output_name_cb,
    .description = wl_output_description_cb,
};

static bool should_control(const char *name) {
    if (ctx.nfilters == 0) return true;
    for (int i = 0; i < ctx.nfilters; i++)
        if (strcmp(ctx.filter_names[i], name) == 0) return true;
    return false;
}

static void registry_global(void *data, struct wl_registry *reg, uint32_t id,
    const char *iface, uint32_t version) {
    if (strcmp(iface, "wl_output") == 0 && ctx.noutputs < MAX_OUTPUTS) {
        struct output *o = &ctx.outputs[ctx.noutputs];
        memset(o, 0, sizeof(*o));
        o->wl_output = wl_registry_bind(reg, id, &wl_output_interface,
            version >= 4 ? 4 : version);
        wl_output_add_listener(o->wl_output, &output_listener, o);
        ctx.noutputs++;
    } else if (strcmp(iface, "zwlr_gamma_control_manager_v1") == 0) {
        ctx.gamma_manager = wl_registry_bind(reg, id,
            &zwlr_gamma_control_manager_v1_interface, 1);
    }
}

static void registry_global_remove(void *data, struct wl_registry *reg, uint32_t id) {}

static const struct wl_registry_listener registry_listener = {
    .global = registry_global,
    .global_remove = registry_global_remove,
};


// MARK: SOCKET

static bool setup_socket(void) {
    if (ctx.sock_path[0] == '\0')
        snprintf(ctx.sock_path, sizeof(ctx.sock_path),
            "/tmp/wlr-brightnessd-%d.sock", getuid());
    unlink(ctx.sock_path);
    ctx.sock_fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (ctx.sock_fd < 0) { perror("socket"); return false; }
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, ctx.sock_path, sizeof(addr.sun_path) - 1);
    if (bind(ctx.sock_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind"); close(ctx.sock_fd); return false;
    }
    listen(ctx.sock_fd, 4);
    return true;
}

static void handle_client(int fd) {
    char buf[128];
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    if (n <= 0) { close(fd); return; }
    buf[n] = '\0';
    while (n > 0 && (buf[n-1] == '\n' || buf[n-1] == '\r' || buf[n-1] == ' '))
        buf[--n] = '\0';

    if (strncmp(buf, "set_brightness ", 15) == 0) {
        const char *rest = buf + 15;
        const char *sp = strchr(rest, ' ');
        int pct;
        if (sp) {
            /* per-output: "set_brightness <name> <pct>" */
            size_t namelen = (size_t)(sp - rest);
            pct = atoi(sp + 1);
            if (pct < 1) pct = 1;
            if (pct > 100) pct = 100;
            bool found = false;
            for (int i = 0; i < ctx.noutputs; i++) {
                if (strncmp(ctx.outputs[i].name, rest, namelen) == 0
                    && ctx.outputs[i].name[namelen] == '\0') {
                    ctx.outputs[i].brightness = pct;
                    apply_gamma(&ctx.outputs[i]);
                    wl_display_flush(ctx.display);
                    found = true;
                    dprintf(fd, "ok %s %d\n", ctx.outputs[i].name, pct);
                    break;
                }
            }
            if (!found)
                dprintf(fd, "error: no such output\n");
        } else {
            /* global: "set_brightness <pct>" */
            pct = atoi(rest);
            if (pct < 1) pct = 1;
            if (pct > 100) pct = 100;
            ctx.brightness = pct;
            for (int i = 0; i < ctx.noutputs; i++)
                ctx.outputs[i].brightness = pct;
            apply_all_gamma();
            dprintf(fd, "ok %d\n", pct);
        }
    } else if (strcmp(buf, "get_brightness") == 0) {
        dprintf(fd, "%d\n", ctx.brightness);
    } else if (strncmp(buf, "set_temp ", 9) == 0) {
        int t = atoi(buf + 9);
        if (t < 0) t = 0;
        ctx.forced_temp = t;
        apply_all_gamma();
        if (t > 0)
            update_timer(time(NULL));
        dprintf(fd, "ok %d\n", t);
    } else if (strcmp(buf, "get_temp") == 0) {
        dprintf(fd, "%d\n", get_temp());
    } else if (strcmp(buf, "status") == 0) {
        for (int i = 0; i < ctx.noutputs; i++) {
            struct output *o = &ctx.outputs[i];
            dprintf(fd, "%s: gamma_size=%u failed=%d ready=%d no_brightness=%d brightness=%d\n",
                o->name, o->gamma_size, o->failed, o->ready, o->no_brightness, o->brightness);
        }
    } else if (strcmp(buf, "reapply") == 0) {
        retry_failed_controls();
        apply_all_gamma();
        dprintf(fd, "ok\n");
    } else if (strcmp(buf, "quit") == 0) {
        dprintf(fd, "ok\n");
        close(fd);
        unlink(ctx.sock_path);
        exit(0);
    } else {
        dprintf(fd, "error: unknown command\n");
    }
    close(fd);
}


// MARK: SIGNALS

static void signal_handler(int sig) {
    write(ctx.signal_pipe[1], &sig, sizeof(sig));
}


// MARK: EVENT LOOP

static void event_loop(void) {
    while (1) {
        fd_set fds;
        FD_ZERO(&fds);
        FD_SET(ctx.sock_fd, &fds);
        FD_SET(ctx.signal_pipe[0], &fds);
        int wl_fd = wl_display_get_fd(ctx.display);
        FD_SET(wl_fd, &fds);
        int maxfd = wl_fd;
        if (ctx.sock_fd > maxfd) maxfd = ctx.sock_fd;
        if (ctx.signal_pipe[0] > maxfd) maxfd = ctx.signal_pipe[0];

        /* blocking select: no periodic poll. gamma re-apply is triggered
         * explicitly via the 'reapply' socket command (called by the
         * brightness popup refresh button or on somewm reload). */
        int ret = select(maxfd + 1, &fds, NULL, NULL, NULL);
        if (ret < 0) {
            if (errno == EINTR) continue;
            perror("select");
            break;
        }

        if (FD_ISSET(wl_fd, &fds))
            wl_display_dispatch(ctx.display);

        if (FD_ISSET(ctx.signal_pipe[0], &fds)) {
            int sig;
            read(ctx.signal_pipe[0], &sig, sizeof(sig));
            if (sig == SIGALRM) {
                ctx.timer_fired = true;
            }
        }

        if (FD_ISSET(ctx.sock_fd, &fds)) {
            int cfd = accept4(ctx.sock_fd, NULL, NULL, SOCK_CLOEXEC);
            if (cfd >= 0)
                handle_client(cfd);
        }

        if (ctx.timer_fired) {
            ctx.timer_fired = false;
            time_t now = time(NULL);
            recalc_stops(now);
            update_timer(now);
            apply_all_gamma();
        }
    }
}


// MARK: MAIN

static int parse_time_of_day(const char *s, time_t *t) {
    struct tm tm = {0};
    if (!strptime(s, "%H:%M", &tm)) return -1;
    *t = tm.tm_hour * 3600 + tm.tm_min * 60;
    return 0;
}

int main(int argc, char *argv[]) {
    ctx.brightness = 100;
    ctx.high_temp = 6500;
    ctx.low_temp = 3500;
    ctx.gamma = 1.0;
    ctx.duration = 1800;
    ctx.latitude = NAN;
    ctx.longitude = NAN;

    for (int i = 1; i < argc; i++) {
        if (i + 1 >= argc) { fprintf(stderr, "missing argument for %s\n", argv[i]); return 1; }
        if (strcmp(argv[i], "-T") == 0) {
            ctx.high_temp = atoi(argv[++i]);
        } else if (strcmp(argv[i], "-t") == 0) {
            ctx.low_temp = atoi(argv[++i]);
        } else if (strcmp(argv[i], "-l") == 0) {
            ctx.latitude = RADIANS(atof(argv[++i]));
        } else if (strcmp(argv[i], "-L") == 0) {
            ctx.longitude = RADIANS(atof(argv[++i]));
        } else if (strcmp(argv[i], "-S") == 0) {
            if (parse_time_of_day(argv[++i], &ctx.sunrise_sec) < 0) {
                fprintf(stderr, "invalid sunrise time\n"); return 1;
            }
            ctx.manual_time = true;
        } else if (strcmp(argv[i], "-s") == 0) {
            if (parse_time_of_day(argv[++i], &ctx.sunset_sec) < 0) {
                fprintf(stderr, "invalid sunset time\n"); return 1;
            }
            ctx.manual_time = true;
        } else if (strcmp(argv[i], "-d") == 0) {
            ctx.duration = atol(argv[++i]);
        } else if (strcmp(argv[i], "-g") == 0) {
            ctx.gamma = atof(argv[++i]);
        } else if (strcmp(argv[i], "-o") == 0) {
            if (ctx.nfilters < MAX_OUTPUTS)
                ctx.filter_names[ctx.nfilters++] = argv[++i];
        } else if (strcmp(argv[i], "--socket") == 0) {
            snprintf(ctx.sock_path, sizeof(ctx.sock_path), "%s", argv[++i]);
        } else if (strcmp(argv[i], "--brightness") == 0) {
            ctx.brightness = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--no-brightness") == 0) {
            if (ctx.n_no_brightness < MAX_OUTPUTS)
                ctx.no_brightness_names[ctx.n_no_brightness++] = argv[++i];
        } else {
            fprintf(stderr, "unknown option: %s\n", argv[i]);
            return 1;
        }
    }

    if (ctx.high_temp <= ctx.low_temp) {
        fprintf(stderr, "high temp must be higher than low temp\n");
        return 1;
    }

    ctx.has_location = !isnan(ctx.latitude) && !isnan(ctx.longitude);
    if (ctx.manual_time)
        ctx.longitude_time_offset = -get_timezone();
    else if (ctx.has_location)
        ctx.longitude_time_offset = longitude_time_offset(ctx.longitude);
    else
        ctx.longitude_time_offset = -get_timezone();

    /* connect to Wayland */
    ctx.display = wl_display_connect(NULL);
    if (!ctx.display) {
        fprintf(stderr, "wlr-brightnessd: cannot connect to Wayland display\n");
        return 1;
    }
    ctx.registry = wl_display_get_registry(ctx.display);
    wl_registry_add_listener(ctx.registry, &registry_listener, NULL);
    wl_display_roundtrip(ctx.display);

    if (!ctx.gamma_manager) {
        fprintf(stderr, "wlr-brightnessd: compositor lacks wlr-gamma-control\n");
        return 1;
    }

    /* create gamma controls for matching outputs */
    wl_display_roundtrip(ctx.display); /* get output names */
    for (int i = 0; i < ctx.noutputs; i++) {
        struct output *o = &ctx.outputs[i];
        if (!should_control(o->name)) continue;
        o->brightness = ctx.brightness;
        for (int j = 0; j < ctx.n_no_brightness; j++) {
            if (strcmp(o->name, ctx.no_brightness_names[j]) == 0) {
                o->no_brightness = true;
                break;
            }
        }
        o->control = zwlr_gamma_control_manager_v1_get_gamma_control(
            ctx.gamma_manager, o->wl_output);
        zwlr_gamma_control_v1_add_listener(o->control, &gamma_listener, o);
    }
    wl_display_roundtrip(ctx.display);

    /* setup signals and timer */
    pipe(ctx.signal_pipe);
    fcntl(ctx.signal_pipe[0], F_SETFL, O_NONBLOCK);
    fcntl(ctx.signal_pipe[1], F_SETFL, O_NONBLOCK);
    struct sigaction sa = {.sa_handler = signal_handler, .sa_flags = 0};
    sigaction(SIGALRM, &sa, NULL);
    timer_create(CLOCK_REALTIME, NULL, &ctx.timer);

    /* setup socket */
    if (!setup_socket()) {
        fprintf(stderr, "wlr-brightnessd: failed to set up socket\n");
        return 1;
    }

    /* initial temperature calculation and apply */
    time_t now = time(NULL);
    recalc_stops(now);
    update_timer(now);
    apply_all_gamma();

    fprintf(stderr, "wlr-brightnessd: ready on %s (brightness=%d%%, temp=%dK, outputs=%d)\n",
        ctx.sock_path, ctx.brightness, get_temp(), ctx.noutputs);

    event_loop();

    unlink(ctx.sock_path);
    return 0;
}
