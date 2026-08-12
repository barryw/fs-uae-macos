#include "macos/include/fsuaemac.h"

#include <pthread.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <memory>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "sysconfig.h"
#include "sysdeps.h"
#include "uae/uae.h"
#include "newcpu.h"
#include "debug.h"
#include "filesys.h"
#include "uae/memory.h"
extern "C" {
#include "fs-uae/config-drives.h"
#include "fs-uae/config-model.h"
#include "fs-uae/fs-uae.h"
#include <fs/base.h>
#include <fs/conf.h>
#include <fs/emu/hacks.h>
#include <fs/emu/path.h>
#include <fs/init.h>
}

namespace {

enum class CommandType { input, mousePosition, pause, reset, floppy, debug, quit };

struct DebugRequest {
    std::mutex mutex;
    std::condition_variable ready;
    bool complete = false;
    std::string output;
};

struct Command {
    CommandType type;
    int first;
    int second;
    std::string path;
    std::shared_ptr<DebugRequest> debug_request;
};

struct StartArguments {
    std::string configuration_path;
};

std::atomic<bool> running{false};
std::atomic<bool> thread_joinable{false};
pthread_t engine_thread;
std::mutex command_mutex;
std::condition_variable command_ready;
std::vector<Command> commands;
bool native_paused;
fsuaemac_video_callback video_callback;
fsuaemac_audio_callback audio_output_callback;
fsuaemac_log_callback log_callback;
fsuaemac_drive_status_callback drive_status_callback;
void *video_context;
void *audio_context;
void *log_context;
void *drive_status_context;
std::atomic<uint64_t> video_sequence{0};
std::atomic<uint64_t> audio_sequence{0};
char last_error[512];
std::vector<uint8_t> render_buffer;
bool mouse_port_pending;
bool drive_status_pending;
std::atomic<double> speed_multiplier{1.0};
std::atomic<uint64_t> timing_generation{1};
std::atomic<uint32_t> health_program_counter{0};
std::atomic<uint32_t> health_exec_base{0};
std::atomic<uint32_t> health_last_alert[4];
std::atomic<uint64_t> health_exception_sequence{0};
std::atomic<uint32_t> health_exception_vector{0};
std::atomic<uint32_t> health_exception_pc{0};
std::atomic<uint32_t> health_exception_address{0};
std::atomic<uint32_t> health_exception_task{0};
std::mutex health_exception_mutex;
char health_exception_task_name[64];
double native_refresh_rate = 50.0;
bool floppy_active[4];
int floppy_count;

int configured_floppy_count();

void clear_exception_health()
{
    std::lock_guard<std::mutex> lock(health_exception_mutex);
    health_exception_sequence = 0;
    health_exception_vector = 0;
    health_exception_pc = 0;
    health_exception_address = 0;
    health_exception_task = 0;
    health_exception_task_name[0] = '\0';
}

void pace_frame()
{
    using Clock = std::chrono::steady_clock;
    static Clock::time_point deadline;
    static uint64_t generation;
    const auto current_generation = timing_generation.load();
    const double speed = speed_multiplier.load();
    const auto now = Clock::now();
    if (speed == 0) {
        deadline = {};
        generation = current_generation;
        return;
    }
    const auto period = std::chrono::duration_cast<Clock::duration>(
        std::chrono::duration<double>(1.0 / (native_refresh_rate * speed)));
    if (deadline == Clock::time_point{} || generation != current_generation ||
        now > deadline + std::chrono::milliseconds(100)) {
        deadline = now;
        generation = current_generation;
    }
    deadline += period;
    std::this_thread::sleep_until(deadline);
}

void *grow_render_buffer(int width, int height)
{
    const size_t size = static_cast<size_t>(width) * height * 4;
    if (render_buffer.size() < size) {
        render_buffer.resize(size);
    }
    return render_buffer.data();
}

void set_error(const char *message)
{
    std::snprintf(last_error, sizeof(last_error), "%s", message);
}

void render_frame(RenderData *data)
{
    if (!data || !data->pixels || data->width <= 0 ||
        data->height <= 0 || data->bpp <= 0) {
        return;
    }

    if (data->refresh_rate > 1) {
        native_refresh_rate = data->refresh_rate;
    }
    fsuaemac_video_frame frame = {
        data->pixels,
        static_cast<uint32_t>(data->width),
        static_cast<uint32_t>(data->height),
        static_cast<uint32_t>(data->width * data->bpp),
        static_cast<uint32_t>(data->limit_x),
        static_cast<uint32_t>(data->limit_y),
        static_cast<uint32_t>(data->limit_w),
        static_cast<uint32_t>(data->limit_h),
        data->refresh_rate,
        static_cast<uint32_t>(data->flags),
        ++video_sequence,
    };
    if (video_callback) {
        video_callback(&frame, video_context);
    }
    pace_frame();
}

int render_audio(int, int16_t *buffer, int size)
{
    if (!audio_output_callback || !buffer || size <= 0) {
        return 1;
    }

    fsuaemac_audio_samples samples = {
        buffer,
        static_cast<uint32_t>(size / (2 * sizeof(int16_t))),
        2,
        44100,
        ++audio_sequence,
    };
    audio_output_callback(&samples, audio_context);
    return 1;
}

void render_log(const char *message)
{
    if (log_callback) {
        log_callback(message, log_context);
    }
}

void publish_drive(uint32_t kind, int index, int active, const char *path)
{
    if (!drive_status_callback) {
        return;
    }
    fsuaemac_drive_status status = {kind, index, active, path ? path : ""};
    drive_status_callback(&status, drive_status_context);
}

void render_led(int led, int state)
{
    if (led >= 0 && led < floppy_count) {
        floppy_active[led] = state != 0;
        publish_drive(FSUAE_MAC_DRIVE_FLOPPY, led, floppy_active[led],
                      amiga_floppy_get_file(led));
    } else if (led == 9) {
        publish_drive(FSUAE_MAC_DRIVE_HARD_DISK, -1, state != 0, "");
    }
}

void render_media(int drive, const char *path)
{
    if (drive >= 0 && drive < floppy_count) {
        publish_drive(FSUAE_MAC_DRIVE_FLOPPY, drive, floppy_active[drive], path);
    }
}

int configured_floppy_count()
{
    if (g_fs_uae_amiga_model == MODEL_CDTV ||
        g_fs_uae_amiga_model == MODEL_CD32) {
        return 0;
    }
    int count = cfg->default_floppy_drive_count;
    for (int drive = 0; drive < 4; ++drive) {
        char key[32];
        std::snprintf(key, sizeof(key), "floppy_drive_%d", drive);
        const char *path = fs_config_get_const_string(key);
        if (path && path[0] && count < drive + 1) {
            count = drive + 1;
        }
    }
    const char *configured = fs_config_get_const_string("floppy_drive_count");
    if (configured && strcasecmp(configured, "auto") != 0) {
        count = std::atoi(configured);
    }
    return count < 0 ? 0 : count > 4 ? 4 : count;
}

void process_commands(int)
{
    health_program_counter = m68k_getpc();
    uint32_t exec_base = 0;
    if (valid_address(4, 4)) {
        const uint32_t candidate = get_long(4);
        if (candidate > 0x100 && valid_address(candidate + 0x202, 16) &&
            get_long(candidate + 0x26) == ~candidate) {
            exec_base = candidate;
            for (int i = 0; i < 4; ++i) {
                health_last_alert[i] = get_long(candidate + 0x202 + i * 4);
            }
        }
    }
    health_exec_base = exec_base;

    if (mouse_port_pending) {
        amiga_set_joystick_port_mode(0, AMIGA_JOYPORT_MOUSE);
        mouse_port_pending = false;
    }
    if (drive_status_pending) {
        for (int drive = 0; drive < floppy_count; ++drive) {
            publish_drive(FSUAE_MAC_DRIVE_FLOPPY, drive, 0,
                          amiga_floppy_get_file(drive));
        }
        for (int drive = 0; drive < 10; ++drive) {
            char key[32];
            std::snprintf(key, sizeof(key), "hard_drive_%d", drive);
            const char *path = fs_config_get_const_string(key);
            if (path && path[0]) {
                publish_drive(FSUAE_MAC_DRIVE_HARD_DISK, drive, 0, path);
            }
        }
        drive_status_pending = false;
    }

    do {
        std::vector<Command> pending;
        {
            std::unique_lock<std::mutex> lock(command_mutex);
            if (native_paused && commands.empty()) {
                command_ready.wait(lock, [] { return !commands.empty(); });
            }
            pending.swap(commands);
        }

        for (const Command &command : pending) {
            switch (command.type) {
                case CommandType::input:
                    amiga_send_input_event(command.first, command.second);
                    break;
                case CommandType::mousePosition:
                    fs_emu_mouse_absolute_x = command.first;
                    fs_emu_mouse_absolute_y = command.second;
                    amiga_send_input_event(INPUTEVENT_MOUSE1_HORIZ, 0);
                    break;
                case CommandType::pause:
                    native_paused = command.first != 0;
                    amiga_pause(native_paused);
                    break;
                case CommandType::reset:
                    clear_exception_health();
                    amiga_reset(command.first);
                    break;
                case CommandType::floppy:
                    amiga_floppy_set_file(command.first, command.path.c_str());
                    break;
                case CommandType::debug:
                    if (command.debug_request) {
                        std::vector<TCHAR> output(1024 * 1024);
#ifdef DEBUGGER
                        debug_parser(command.path.c_str(), output.data(), output.size());
#else
                        std::snprintf(output.data(), output.size(), "Debugger is unavailable\n");
#endif
                        std::lock_guard<std::mutex> lock(command.debug_request->mutex);
                        command.debug_request->output = output.data();
                        command.debug_request->complete = true;
                        command.debug_request->ready.notify_one();
                    }
                    break;
                case CommandType::quit:
                    native_paused = false;
                    amiga_quit();
                    break;
            }
        }
    } while (native_paused);
}

void configure_machine()
{
    amiga_set_led_function(render_led);
    amiga_set_media_function(render_media);
    fs_uae_configure_amiga_hardware();
    fs_uae_configure_floppies();
    floppy_count = configured_floppy_count();
    fs_uae_configure_hard_drives();
    const char *exchange = std::getenv("FSUAE_MAC_EXCHANGE_DIRECTORY");
    if (exchange && exchange[0]) {
        fs_uae_configure_host_directory(exchange, "MCP", "MCP", -128);
    }
    fs_uae_configure_cdrom();
    const char *absolute_mouse = std::getenv("FSUAE_MAC_ABSOLUTE_MOUSE");
    if (absolute_mouse && absolute_mouse[0]) {
        amiga_set_option("magic_mouse", "yes");
        amiga_set_option("absolute_mouse", "mousehack");
    }
    mouse_port_pending = true;
    drive_status_pending = true;
    fs_uae_configure_directories();
    fs_uae_set_uae_paths();
    fs_uae_read_custom_uae_options(0, nullptr);

}

void *run_engine(void *opaque)
{
    StartArguments *arguments = static_cast<StartArguments *>(opaque);
    const std::string configuration_path = arguments->configuration_path;
    delete arguments;

    fs_init();
    fs_set_prgname("fs-uae");
    fs_set_application_name("FS-UAE Mac");
    amiga_init();
    g_fs_uae_config_file_path = strdup(configuration_path.c_str());
    const size_t separator = configuration_path.find_last_of('/');
    const std::string configuration_dir = separator == std::string::npos
        ? "." : configuration_path.substr(0, separator);
    g_fs_uae_config_dir_path = strdup(configuration_dir.c_str());
    fs_emu_path_set_expand_function(fs_uae_expand_path);
    fs_config_read_file(configuration_path.c_str(), 0);
    for (int drive = 0; drive < 4; ++drive) {
        char environment_key[32];
        char option_key[32];
        std::snprintf(environment_key, sizeof(environment_key),
                      "FSUAE_MAC_FLOPPY_%d", drive);
        const char *override_path = std::getenv(environment_key);
        if (override_path) {
            std::snprintf(option_key, sizeof(option_key), "floppy_drive_%d", drive);
            fs_config_set_string(option_key, override_path);
        }
    }
    for (int drive = 0; drive < 10; ++drive) {
        char environment_key[48];
        char option_key[48];
        std::snprintf(environment_key, sizeof(environment_key),
                      "FSUAE_MAC_HARD_DRIVE_%d", drive);
        const char *override_path = std::getenv(environment_key);
        if (!override_path || !override_path[0]) {
            continue;
        }
        std::snprintf(option_key, sizeof(option_key), "hard_drive_%d", drive);
        fs_config_set_string(option_key, override_path);
        std::snprintf(option_key, sizeof(option_key),
                      "hard_drive_%d_read_only", drive);
        std::snprintf(environment_key, sizeof(environment_key),
                      "FSUAE_MAC_HARD_DRIVE_%d_READ_ONLY", drive);
        const char *read_only = std::getenv(environment_key);
        fs_config_set_string(option_key, read_only ? read_only : "0");
        std::snprintf(option_key, sizeof(option_key), "hard_drive_%d_type", drive);
        fs_config_set_string(option_key, "");
        std::snprintf(option_key, sizeof(option_key), "hard_drive_%d_controller", drive);
        fs_config_set_string(option_key, "uae");
        std::snprintf(option_key, sizeof(option_key), "hard_drive_%d_priority", drive);
        fs_config_set_string(option_key, "-128");
        std::snprintf(option_key, sizeof(option_key), "hard_drive_%d_file_system", drive);
        fs_config_set_string(option_key, "");
    }
    native_refresh_rate = fs_config_get_boolean("ntsc_mode") == 1 ? 59.94 : 50.0;
    ++timing_generation;
    fs_uae_init_path_resolver();
    fs_uae_configure_amiga_model();
    amiga_set_video_format(AMIGA_VIDEO_FORMAT_BGRA);
    fs_emu_video_scale_x = 1.0;
    fs_emu_video_scale_y = 1.0;
    fs_emu_video_offset_x = 0.0;
    fs_emu_video_offset_y = 0.0;
    // Keep the native runtime's Picasso96 mode IDs aligned with FS-UAE 3.x.
    amiga_add_rtg_resolution(672, 540);
    amiga_add_rtg_resolution(960, 540);
    amiga_add_rtg_resolution(1344, 1080);
    render_buffer.assign(3072 * 2048 * 4, 0);
    amiga_set_render_buffer(render_buffer.data(), render_buffer.size(), 1,
                            grow_render_buffer);
    amiga_set_render_function(render_frame);
    amiga_set_audio_callback(render_audio);
    amiga_set_audio_frequency(44100);
    amiga_set_event_function(process_commands);
    amiga_set_init_function(configure_machine);
    amiga_set_log_function(render_log);
    amiga_set_gui_message_function(render_log);

    amiga_main();
    running = false;
    return nullptr;
}

int queue_command(Command command)
{
    if (!running) {
        return 0;
    }
    {
        std::lock_guard<std::mutex> lock(command_mutex);
        commands.push_back(std::move(command));
    }
    command_ready.notify_one();
    return 1;
}

} // namespace

extern "C" {

void uae_cpu_exception_hook(int vector, uae_u32 pc, uae_u32 address)
{
    uint32_t task = 0;
    char task_name[64] = {};
    if (valid_address(4, 4)) {
        const uint32_t exec_base = get_long(4);
        if (exec_base > 0x100 && valid_address(exec_base + 0x114, 4)) {
            task = get_long(exec_base + 0x114);
        }
    }
    if (task && valid_address(task + 10, 4)) {
        const uint32_t name = get_long(task + 10);
        for (size_t index = 0; name && index + 1 < sizeof(task_name) &&
             valid_address(name + index, 1); ++index) {
            task_name[index] = static_cast<char>(get_byte(name + index));
            if (!task_name[index]) break;
        }
    }

    std::lock_guard<std::mutex> lock(health_exception_mutex);
    if (health_exception_sequence != 0) return;
    health_exception_vector = static_cast<uint32_t>(vector);
    health_exception_pc = pc;
    health_exception_address = address;
    health_exception_task = task;
    std::snprintf(health_exception_task_name,
                  sizeof(health_exception_task_name), "%s", task_name);
    ++health_exception_sequence;
}

void fsuaemac_set_video_callback(fsuaemac_video_callback callback, void *context)
{
    video_callback = callback;
    video_context = context;
}

void fsuaemac_set_audio_callback(fsuaemac_audio_callback callback, void *context)
{
    audio_output_callback = callback;
    audio_context = context;
}

void fsuaemac_set_log_callback(fsuaemac_log_callback callback, void *context)
{
    log_callback = callback;
    log_context = context;
}

void fsuaemac_set_drive_status_callback(fsuaemac_drive_status_callback callback,
                                        void *context)
{
    drive_status_callback = callback;
    drive_status_context = context;
}

int fsuaemac_start(const fsuaemac_configuration *configuration)
{
    if (!configuration || !configuration->configuration_path ||
        !configuration->configuration_path[0]) {
        set_error("Missing configuration");
        return 0;
    }
    FILE *file = std::fopen(configuration->configuration_path, "r");
    if (!file) {
        set_error("Configuration file could not be opened");
        return 0;
    }
    std::fclose(file);
    if (thread_joinable.exchange(true)) {
        set_error("FS-UAE is already running");
        return 0;
    }
    {
        std::lock_guard<std::mutex> lock(command_mutex);
        commands.clear();
        native_paused = false;
    }
    clear_exception_health();
    running = true;

    auto *arguments = new StartArguments;
    arguments->configuration_path = configuration->configuration_path;

    if (pthread_create(&engine_thread, nullptr, run_engine, arguments) != 0) {
        delete arguments;
        running = false;
        thread_joinable = false;
        set_error("Could not create the FS-UAE engine thread");
        return 0;
    }
    last_error[0] = '\0';
    return 1;
}

int fsuaemac_is_running(void)
{
    return running;
}

int fsuaemac_get_health(fsuaemac_health *health)
{
    if (!health || !running) {
        return 0;
    }
    health->frame_sequence = video_sequence.load();
    health->program_counter = health_program_counter.load();
    health->exec_base = health_exec_base.load();
    for (int i = 0; i < 4; ++i) {
        health->last_alert[i] = health_last_alert[i].load();
    }
    health->guest_control_ready = filesys_guest_control_is_ready();
    health->guest_control_heartbeat = filesys_guest_control_heartbeat();
    health->guest_control_generation = filesys_guest_control_generation();
    {
        std::lock_guard<std::mutex> lock(health_exception_mutex);
        health->exception_sequence = health_exception_sequence.load();
        health->exception_vector = health_exception_vector.load();
        health->exception_pc = health_exception_pc.load();
        health->exception_address = health_exception_address.load();
        health->exception_task = health_exception_task.load();
        std::snprintf(health->exception_task_name,
                      sizeof(health->exception_task_name), "%s",
                      health_exception_task_name);
    }
    return 1;
}

void fsuaemac_clear_exception(void)
{
    clear_exception_health();
}

void fsuaemac_stop(void)
{
    if (!thread_joinable.exchange(false)) {
        return;
    }
    if (running) {
        queue_command({CommandType::quit, 0, 0, {}, {}});
    }
    pthread_join(engine_thread, nullptr);
    running = false;
}

int fsuaemac_queue_input(int32_t event, int32_t state)
{
    return queue_command({CommandType::input, event, state, {}, {}});
}

int fsuaemac_queue_key(uint16_t key, int32_t pressed)
{
#define MAP(KEY, EVENT) case KEY: return fsuaemac_queue_input(EVENT, pressed != 0)
    switch (key) {
        MAP(0, INPUTEVENT_KEY_A); MAP(1, INPUTEVENT_KEY_S);
        MAP(2, INPUTEVENT_KEY_D); MAP(3, INPUTEVENT_KEY_F);
        MAP(4, INPUTEVENT_KEY_H); MAP(5, INPUTEVENT_KEY_G);
        MAP(6, INPUTEVENT_KEY_Z); MAP(7, INPUTEVENT_KEY_X);
        MAP(8, INPUTEVENT_KEY_C); MAP(9, INPUTEVENT_KEY_V);
        MAP(11, INPUTEVENT_KEY_B); MAP(12, INPUTEVENT_KEY_Q);
        MAP(13, INPUTEVENT_KEY_W); MAP(14, INPUTEVENT_KEY_E);
        MAP(15, INPUTEVENT_KEY_R); MAP(16, INPUTEVENT_KEY_Y);
        MAP(17, INPUTEVENT_KEY_T); MAP(18, INPUTEVENT_KEY_1);
        MAP(19, INPUTEVENT_KEY_2); MAP(20, INPUTEVENT_KEY_3);
        MAP(21, INPUTEVENT_KEY_4); MAP(22, INPUTEVENT_KEY_6);
        MAP(23, INPUTEVENT_KEY_5); MAP(24, INPUTEVENT_KEY_EQUALS);
        MAP(25, INPUTEVENT_KEY_9); MAP(26, INPUTEVENT_KEY_7);
        MAP(27, INPUTEVENT_KEY_SUB); MAP(28, INPUTEVENT_KEY_8);
        MAP(29, INPUTEVENT_KEY_0); MAP(30, INPUTEVENT_KEY_RIGHTBRACKET);
        MAP(31, INPUTEVENT_KEY_O); MAP(32, INPUTEVENT_KEY_U);
        MAP(33, INPUTEVENT_KEY_LEFTBRACKET); MAP(34, INPUTEVENT_KEY_I);
        MAP(35, INPUTEVENT_KEY_P); MAP(36, INPUTEVENT_KEY_RETURN);
        MAP(37, INPUTEVENT_KEY_L); MAP(38, INPUTEVENT_KEY_J);
        MAP(39, INPUTEVENT_KEY_SINGLEQUOTE); MAP(40, INPUTEVENT_KEY_K);
        MAP(41, INPUTEVENT_KEY_SEMICOLON); MAP(42, INPUTEVENT_KEY_BACKSLASH);
        MAP(43, INPUTEVENT_KEY_COMMA); MAP(44, INPUTEVENT_KEY_DIV);
        MAP(45, INPUTEVENT_KEY_N); MAP(46, INPUTEVENT_KEY_M);
        MAP(47, INPUTEVENT_KEY_PERIOD); MAP(48, INPUTEVENT_KEY_TAB);
        MAP(49, INPUTEVENT_KEY_SPACE); MAP(50, INPUTEVENT_KEY_BACKQUOTE);
        MAP(10, INPUTEVENT_KEY_30);
        MAP(51, INPUTEVENT_KEY_BACKSPACE); MAP(53, INPUTEVENT_KEY_ESC);
        MAP(54, INPUTEVENT_KEY_AMIGA_RIGHT); MAP(55, INPUTEVENT_KEY_AMIGA_LEFT);
        MAP(56, INPUTEVENT_KEY_SHIFT_LEFT);
        MAP(57, INPUTEVENT_KEY_CAPS_LOCK); MAP(58, INPUTEVENT_KEY_ALT_LEFT);
        MAP(59, INPUTEVENT_KEY_CTRL); MAP(60, INPUTEVENT_KEY_SHIFT_RIGHT);
        MAP(61, INPUTEVENT_KEY_ALT_RIGHT); MAP(62, INPUTEVENT_KEY_CTRL);
        MAP(65, INPUTEVENT_KEY_NP_PERIOD); MAP(67, INPUTEVENT_KEY_NP_MUL);
        MAP(69, INPUTEVENT_KEY_NP_ADD); MAP(75, INPUTEVENT_KEY_NP_DIV);
        MAP(76, INPUTEVENT_KEY_ENTER); MAP(78, INPUTEVENT_KEY_NP_SUB);
        MAP(82, INPUTEVENT_KEY_NP_0); MAP(83, INPUTEVENT_KEY_NP_1);
        MAP(84, INPUTEVENT_KEY_NP_2); MAP(85, INPUTEVENT_KEY_NP_3);
        MAP(86, INPUTEVENT_KEY_NP_4); MAP(87, INPUTEVENT_KEY_NP_5);
        MAP(88, INPUTEVENT_KEY_NP_6); MAP(89, INPUTEVENT_KEY_NP_7);
        MAP(91, INPUTEVENT_KEY_NP_8); MAP(92, INPUTEVENT_KEY_NP_9);
        MAP(96, INPUTEVENT_KEY_F5); MAP(97, INPUTEVENT_KEY_F6);
        MAP(98, INPUTEVENT_KEY_F7); MAP(100, INPUTEVENT_KEY_F8);
        MAP(101, INPUTEVENT_KEY_F9); MAP(109, INPUTEVENT_KEY_F10);
        MAP(122, INPUTEVENT_KEY_F1); MAP(120, INPUTEVENT_KEY_F2);
        MAP(99, INPUTEVENT_KEY_F3); MAP(118, INPUTEVENT_KEY_F4);
        MAP(114, INPUTEVENT_KEY_2B); MAP(115, INPUTEVENT_KEY_NP_LPAREN);
        MAP(116, INPUTEVENT_KEY_NP_RPAREN); MAP(117, INPUTEVENT_KEY_DEL);
        MAP(119, INPUTEVENT_KEY_HELP); MAP(121, INPUTEVENT_KEY_AMIGA_RIGHT);
        MAP(123, INPUTEVENT_KEY_CURSOR_LEFT);
        MAP(124, INPUTEVENT_KEY_CURSOR_RIGHT);
        MAP(125, INPUTEVENT_KEY_CURSOR_DOWN);
        MAP(126, INPUTEVENT_KEY_CURSOR_UP);
        default: return 0;
    }
#undef MAP
}

int fsuaemac_queue_mouse_move(int32_t delta_x, int32_t delta_y)
{
    if (!running) {
        return 0;
    }
    std::lock_guard<std::mutex> lock(command_mutex);
    if (delta_x) {
        commands.push_back({CommandType::input, INPUTEVENT_MOUSE1_HORIZ,
                            delta_x, {}, {}});
    }
    if (delta_y) {
        commands.push_back({CommandType::input, INPUTEVENT_MOUSE1_VERT,
                            delta_y, {}, {}});
    }
    return 1;
}

int fsuaemac_queue_mouse_position(int32_t x, int32_t y)
{
    if (x < 0 || y < 0) {
        return 0;
    }
    return queue_command({CommandType::mousePosition, x, y, {}, {}});
}

int fsuaemac_queue_mouse_button(uint32_t button, int32_t pressed)
{
    int event;
    switch (button) {
        case 0: event = INPUTEVENT_JOY1_FIRE_BUTTON; break;
        case 1: event = INPUTEVENT_JOY1_3RD_BUTTON; break;
        case 2: event = INPUTEVENT_JOY1_2ND_BUTTON; break;
        default: return 0;
    }
    return fsuaemac_queue_input(event, pressed != 0);
}

int fsuaemac_set_speed(double multiplier)
{
    if (multiplier < 0 || multiplier > 4) {
        return 0;
    }
    speed_multiplier = multiplier;
    ++timing_generation;
    return 1;
}

int fsuaemac_queue_pause(int32_t paused)
{
    return queue_command({CommandType::pause, paused != 0, 0, {}, {}});
}

int fsuaemac_queue_reset(int32_t hard)
{
    return queue_command({CommandType::reset, hard != 0, 0, {}, {}});
}

int fsuaemac_queue_floppy(int32_t drive, const char *path)
{
    if (drive < 0 || drive >= 4 || !path) {
        return 0;
    }
    return queue_command({CommandType::floppy, drive, 0, path, {}});
}

int fsuaemac_debug_command(const char *command, char *output,
                           uint32_t output_size, uint32_t timeout_ms)
{
    if (!command || !output || output_size == 0 || std::strlen(command) >= 100) {
        set_error("Invalid debugger command");
        return 0;
    }
    auto request = std::make_shared<DebugRequest>();
    if (!queue_command({CommandType::debug, 0, 0, command, request})) {
        return 0;
    }
    std::unique_lock<std::mutex> lock(request->mutex);
    if (!request->ready.wait_for(lock, std::chrono::milliseconds(timeout_ms),
                                 [&] { return request->complete; })) {
        set_error("Debugger command timed out");
        return 0;
    }
    std::snprintf(output, output_size, "%s", request->output.c_str());
    return 1;
}

const char *fsuaemac_last_error(void)
{
    return last_error;
}

} // extern "C"
