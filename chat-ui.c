/* chat-ui.c -- E-INK CHAT: a small GTK chat window over llama-server.
 *
 * The rest of the project runs the model. This is its face: a transcript of
 * chat bubbles, an entry line and an on-screen keyboard, drawn with the toolkit
 * the Kindle's own UI uses (GTK over X). It talks to llama-server over HTTP and
 * streams the answer in token by token, so nothing here depends on KOReader.
 *
 * The same source builds against GTK 3 (a PC, this repository's host build) and
 * GTK 2 (the Kindle SDK, which is GTK 2 only). The GTK 3 path adds CSS; the
 * GTK 2 path styles widgets the old way (modify_bg/modify_font), so the two
 * look different but behave the same.
 *
 * Usage:
 *   chat-ui [--app-dir DIR] [--host H] [--port N] [--model FILE]
 *           [--server-bin FILE] [--server-args "..."] [--no-spawn]
 *           [--font-size N] [--fullscreen] [--keyboard on|off]
 *           [--native-keyboard] [--refresh-cmd CMD] [--self-test]
 *
 * MIT. See the repository LICENSE.
 */

#include <gtk/gtk.h>
#include <glib.h>
#include <glib/gstdio.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <sys/types.h>

#define CHATUI_VERSION "0.3.0"
#define APP_ID "com.kumanaya.einkchat"
#define DEFAULT_APP_DIR "/mnt/us/extensions/kindlechat"
#define DEFAULT_SYSTEM "You are a helpful assistant running on a Kindle e-reader. Answer in plain text, at most three short sentences."

/* --- configuration -------------------------------------------------------- */

static struct {
    char *app_dir;
    char *host;
    char *model;
    char *server_bin;
    char *server_args;
    char *refresh_cmd;
    char *system;
    int port;
    int font_size;
    int max_turns;
    gboolean no_spawn;
    gboolean fullscreen;
    gboolean native_kbd;
    gboolean keyboard_on;
    gboolean self_test;
} cfg = {
    .app_dir = DEFAULT_APP_DIR,
    .host = "127.0.0.1",
    .port = 8080,
    .font_size = 18,
    .max_turns = 10,
    .keyboard_on = TRUE,
};

/* --- GTK 2 / GTK 3 shims -------------------------------------------------- */

#if GTK_MAJOR_VERSION < 3
#define gtk_box_new(o, s) \
    ((o) == GTK_ORIENTATION_HORIZONTAL ? gtk_hbox_new(FALSE, (s)) : gtk_vbox_new(FALSE, (s)))
#endif

static GtkWidget *box_new(GtkOrientation orientation, gint spacing) {
    return gtk_box_new(orientation, spacing);
}

static void widget_set_visible(GtkWidget *w, gboolean visible) {
    if (visible) gtk_widget_show(w);
    else gtk_widget_hide(w);
}

static gboolean widget_is_visible(GtkWidget *w) {
#if GTK_MAJOR_VERSION >= 3
    return gtk_widget_get_visible(w);
#else
    return GTK_WIDGET_VISIBLE(w);
#endif
}

static void widget_add_class(GtkWidget *w, const char *cls) {
#if GTK_MAJOR_VERSION >= 3
    gtk_style_context_add_class(gtk_widget_get_style_context(w), cls);
#else
    (void)w;
    (void)cls;
#endif
}

static void widget_set_id(GtkWidget *w, const char *name) {
    gtk_widget_set_name(w, name);
}

static void label_set_xalign(GtkWidget *label, float x) {
#if GTK_MAJOR_VERSION >= 3
    gtk_label_set_xalign(GTK_LABEL(label), x);
#else
    gtk_misc_set_alignment(GTK_MISC(label), x, 0.5f);
#endif
}

static void label_set_padding(GtkWidget *label, gint xpad, gint ypad) {
#if GTK_MAJOR_VERSION >= 3
    gtk_widget_set_margin_start(label, xpad);
    gtk_widget_set_margin_end(label, xpad);
    gtk_widget_set_margin_top(label, ypad);
    gtk_widget_set_margin_bottom(label, ypad);
#else
    gtk_misc_set_padding(GTK_MISC(label), xpad, ypad);
#endif
}

static void widget_set_bold(GtkWidget *w) {
#if GTK_MAJOR_VERSION < 3
    PangoFontDescription *font =
        pango_font_description_from_string(g_strdup_printf("Sans Bold %d", cfg.font_size));
    gtk_widget_modify_font(w, font);
    pango_font_description_free(font);
#else
    (void)w;
#endif
}

static void widget_set_color(GtkWidget *w, const char *color) {
#if GTK_MAJOR_VERSION < 3
    GdkColor c;
    if (gdk_color_parse(color, &c)) gtk_widget_modify_fg(w, GTK_STATE_NORMAL, &c);
#else
    (void)w;
    (void)color;
#endif
}

static void load_style(void) {
#if GTK_MAJOR_VERSION >= 3
    /* 8-bpp e-ink (qemu-kindle4 / i.MX50 EPDC): no grey fills, no radius.
     * Grey ghosts. User turns invert; the reply stays a 2px black frame. */
    char *css = g_strdup_printf(
        "window, GtkScrolledWindow, GtkViewport { background-color: #ffffff; }\n"
        "button { background-image: none; background-color: #ffffff; color: #000000;\n"
        "  border: 2px solid #000000; border-radius: 0; padding: 6px 10px; }\n"
        "button:disabled { background-color: #ffffff; color: #000000; opacity: 0.5; }\n"
        ".header { background-color: #000000; padding: 8px 12px; }\n"
        ".header label { color: #ffffff; font-weight: bold; font-size: %dpx; }\n"
        ".header .status { font-size: %dpx; font-weight: normal; }\n"
        ".header button { background-color: #000000; color: #ffffff; border-color: #ffffff; }\n"
        ".hint { padding: 24px 16px; font-size: %dpx; }\n"
        ".bubble { padding: 10px 12px; margin: 4px 8px; font-size: %dpx; }\n"
        ".bubble.user { background-color: #000000; margin-left: 48px; }\n"
        ".bubble.user label { color: #ffffff; }\n"
        ".bubble.bot { background-color: #ffffff; margin-right: 48px; }\n"
        ".bubbleborder { background-color: #000000; }\n"
        ".keyboard { padding: 4px 4px 8px 4px; background-color: #ffffff; }\n"
        ".keyboard button { min-height: 48px; }\n"
        ".composer { padding: 6px 6px 8px 6px; }\n"
        ".composer button { min-width: 64px; min-height: 48px; }\n"
        "#entry { font-size: %dpx; border: 2px solid #000000; border-radius: 0;\n"
        "  padding: 8px; background-color: #ffffff; }",
        cfg.font_size, cfg.font_size - 2, cfg.font_size, cfg.font_size, cfg.font_size);
    GtkCssProvider *provider = gtk_css_provider_new();
    gtk_css_provider_load_from_data(provider, css, -1, NULL);
    gtk_style_context_add_provider_for_screen(gdk_screen_get_default(), GTK_STYLE_PROVIDER(provider),
                                              GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref(provider);
    g_free(css);
#else
    char *rc = g_strdup_printf(
        "style \"chatui-base\" {\n"
        "  font_name = \"Sans %d\"\n"
        "  fg[NORMAL] = \"#000000\"\n"
        "  text[NORMAL] = \"#000000\"\n"
        "  bg[NORMAL] = \"#ffffff\"\n"
        "  base[NORMAL] = \"#ffffff\"\n"
        "}\n"
        "style \"chatui-header\" {\n"
        "  bg[NORMAL] = \"#000000\"\n"
        "  fg[NORMAL] = \"#ffffff\"\n"
        "  text[NORMAL] = \"#ffffff\"\n"
        "}\n"
        "style \"chatui-key\" {\n"
        "  bg[NORMAL] = \"#ffffff\"\n"
        "  fg[NORMAL] = \"#000000\"\n"
        "}\n"
        "style \"chatui-user\" {\n"
        "  bg[NORMAL] = \"#000000\"\n"
        "  fg[NORMAL] = \"#ffffff\"\n"
        "  text[NORMAL] = \"#ffffff\"\n"
        "}\n"
        "widget_class \"*\" style \"chatui-base\"\n"
        "widget \"*chatui-header*\" style \"chatui-header\"\n"
        "widget \"*chatui-key*\" style \"chatui-key\"\n"
        "widget \"*chatui-user*\" style \"chatui-user\"\n",
        cfg.font_size);
    gtk_rc_parse_string(rc);
    g_free(rc);
#endif
}

static void style_header(GtkWidget *header) {
#if GTK_MAJOR_VERSION >= 3
    widget_add_class(header, "header");
#else
    GdkColor black;
    gdk_color_parse("#000000", &black);
    gtk_widget_modify_bg(header, GTK_STATE_NORMAL, &black);
#endif
}

static void style_bubble(GtkWidget *bubble, const char *role) {
#if GTK_MAJOR_VERSION >= 3
    gchar *cls = g_strdup_printf("bubble %s", role);
    widget_add_class(bubble, cls);
    g_free(cls);
#else
    GdkColor c;
    if (g_strcmp0(role, "user") == 0) gdk_color_parse("#000000", &c);
    else gdk_color_parse("#ffffff", &c);
    gtk_widget_modify_bg(bubble, GTK_STATE_NORMAL, &c);
#endif
}

/* The bot bubble gets a 1px black frame: an outer event box painted black,
 * the inner one holding the text. */
static void style_border(GtkWidget *w) {
#if GTK_MAJOR_VERSION >= 3
    widget_add_class(w, "bubbleborder");
#else
    GdkColor black;
    gdk_color_parse("#000000", &black);
    gtk_widget_modify_bg(w, GTK_STATE_NORMAL, &black);
#endif
}

/* --- state ---------------------------------------------------------------- */

typedef struct {
    char *role;
    char *content;
} Message;

typedef struct {
    GPid pid;
    guint out_watch;
    GIOChannel *out_ch;
    GString *pending; /* partial SSE line */
    GString *answer;  /* answer so far */
    GtkWidget *bubble;
} Turn;

static GPtrArray *history; /* Message* */
static Turn *turn;
static gboolean streaming;

static GtkWidget *window, *transcript, *scrolled, *entry, *send_btn, *stop_btn, *new_btn;
static GtkWidget *status_label, *kbd_box, *shift_btn;
static GtkAdjustment *vadj;
static char *request_path;

static gboolean server_ready;
static gboolean server_spawned;
static GPid server_pid;
static int health_polls;

static void msg_free(gpointer p) {
    Message *m = p;
    g_free(m->role);
    g_free(m->content);
    g_free(m);
}

/* --- JSON ----------------------------------------------------------------- */

static void json_escape_append(GString *out, const char *s) {
    for (; s && *s; s++) {
        switch (*s) {
        case '"': g_string_append(out, "\\\""); break;
        case '\\': g_string_append(out, "\\\\"); break;
        case '\n': g_string_append(out, "\\n"); break;
        case '\r': g_string_append(out, "\\r"); break;
        case '\t': g_string_append(out, "\\t"); break;
        default:
            if ((guchar)*s < 0x20) g_string_append_printf(out, "\\u%04x", (guchar)*s);
            else g_string_append_c(out, *s);
        }
    }
}

static void add_history(const char *role, const char *content) {
    Message *m = g_new0(Message, 1);
    m->role = g_strdup(role);
    m->content = g_strdup(content);
    g_ptr_array_add(history, m);
}

/* The full conversation, trimmed to the newest turns that fit the context. */
static GString *build_request(void) {
    GString *req = g_string_new(
        "{\"model\":\"local\",\"stream\":true,\"max_tokens\":256,\"temperature\":0.7,\"messages\":[");
    g_string_append(req, "{\"role\":\"system\",\"content\":\"");
    json_escape_append(req, cfg.system ? cfg.system : DEFAULT_SYSTEM);
    g_string_append(req, "\"}");

    guint start = history->len;
    int budget = 2200; /* characters, roughly 700 tokens: leaves room for the answer */
    guint kept = 0;
    while (start > 0) {
        Message *m = g_ptr_array_index(history, start - 1);
        int cost = (int)strlen(m->content) + 16;
        if (kept >= (guint)cfg.max_turns || cost > budget) break;
        budget -= cost;
        start--;
        kept++;
    }
    for (guint i = start; i < history->len; i++) {
        Message *m = g_ptr_array_index(history, i);
        g_string_append_printf(req, ",{\"role\":\"%s\",\"content\":\"", m->role);
        json_escape_append(req, m->content);
        g_string_append(req, "\"}");
    }
    g_string_append(req, "]}");
    return req;
}

/* --- SSE ------------------------------------------------------------------ */

/* Copies a JSON string body (after the opening quote) into out. */
static void copy_json_string(const char *p, GString *out) {
    while (*p && *p != '"') {
        if (*p == '\\' && p[1]) {
            p++;
            switch (*p) {
            case 'n': g_string_append_c(out, '\n'); break;
            case 't': g_string_append_c(out, '\t'); break;
            case 'r': g_string_append_c(out, '\r'); break;
            case 'b': g_string_append_c(out, '\b'); break;
            case 'f': g_string_append_c(out, '\f'); break;
            case '"': g_string_append_c(out, '"'); break;
            case '\\': g_string_append_c(out, '\\'); break;
            case '/': g_string_append_c(out, '/'); break;
            case 'u': {
                guint code = 0;
                if (sscanf(p + 1, "%4x", &code) == 1) {
                    /* Lone surrogates are dropped; enough for a chat prototype. */
                    g_string_append_unichar(out, (gunichar)code);
                    p += 4;
                }
                break;
            }
            default: g_string_append_c(out, *p);
            }
            p++;
        } else {
            g_string_append_c(out, *p++);
        }
    }
}

static char *json_field(const char *line, const char *from, const char *field) {
    const char *p = strstr(line, from);
    if (!p) return NULL;
    p = strstr(p, field);
    if (!p) return NULL;
    p += strlen(field);
    if (*p != '"') return NULL;
    GString *out = g_string_new(NULL);
    copy_json_string(p + 1, out);
    return g_string_free(out, FALSE);
}

static char *sse_delta_content(const char *line) {
    return json_field(line, "\"delta\"", "\"content\":");
}

static char *sse_error_message(const char *line) {
    char *msg = json_field(line, "\"error\"", "\"message\":");
    if (!msg) msg = g_strdup("the server returned an error");
    return msg;
}

/* --- transcript ----------------------------------------------------------- */

static void scroll_to_bottom(void);

#define WELCOME "Ask a question.\nThe model runs on this Kindle. Nothing leaves the device."

static GtkWidget *add_hint(const char *text) {
    GtkWidget *row = box_new(GTK_ORIENTATION_VERTICAL, 0);
    GtkWidget *label = gtk_label_new(text);
    widget_add_class(label, "hint");
    label_set_xalign(label, 0.0f);
    label_set_padding(label, 16, 20);
    gtk_label_set_line_wrap(GTK_LABEL(label), TRUE);
    gtk_label_set_line_wrap_mode(GTK_LABEL(label), PANGO_WRAP_WORD_CHAR);
    gtk_label_set_selectable(GTK_LABEL(label), FALSE);
    gtk_box_pack_start(GTK_BOX(row), label, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(transcript), row, FALSE, FALSE, 0);
    gtk_widget_show_all(row);
    return label;
}

static GtkWidget *add_bubble(const char *role, const char *text) {
    gboolean user = g_strcmp0(role, "user") == 0;
    GtkWidget *row = box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    GtkWidget *spacer = box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    GtkWidget *bubble = gtk_event_box_new();
    GtkWidget *content = box_new(GTK_ORIENTATION_VERTICAL, 0);
    GtkWidget *who = gtk_label_new(NULL);
    GtkWidget *label = gtk_label_new(text);

    gtk_label_set_markup(GTK_LABEL(who), user ? "<b>You</b>" : "<b>Kindle</b>");
    label_set_xalign(who, 0.0f);
    label_set_xalign(label, 0.0f);
    label_set_padding(who, 10, 2);
    label_set_padding(label, 10, 6);
    gtk_label_set_line_wrap(GTK_LABEL(label), TRUE);
    gtk_label_set_line_wrap_mode(GTK_LABEL(label), PANGO_WRAP_WORD_CHAR);
    gtk_label_set_selectable(GTK_LABEL(label), FALSE);
    gtk_box_pack_start(GTK_BOX(content), who, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(content), label, FALSE, FALSE, 0);

    if (user) {
        style_bubble(bubble, "user");
        widget_set_id(bubble, "chatui-user");
#if GTK_MAJOR_VERSION < 3
        widget_set_color(who, "#ffffff");
        widget_set_color(label, "#ffffff");
#endif
        gtk_container_add(GTK_CONTAINER(bubble), content);
        gtk_box_pack_start(GTK_BOX(row), spacer, TRUE, TRUE, 0);
        gtk_box_pack_end(GTK_BOX(row), bubble, FALSE, FALSE, 8);
    } else {
        GtkWidget *inner = gtk_event_box_new();
        style_border(bubble);
        style_bubble(inner, "bot");
        widget_set_id(inner, "chatui-bubble");
        gtk_container_set_border_width(GTK_CONTAINER(bubble), 2);
        gtk_container_add(GTK_CONTAINER(inner), content);
        gtk_container_add(GTK_CONTAINER(bubble), inner);
        gtk_box_pack_start(GTK_BOX(row), bubble, FALSE, FALSE, 8);
        gtk_box_pack_end(GTK_BOX(row), spacer, TRUE, TRUE, 0);
    }
    gtk_box_pack_start(GTK_BOX(transcript), row, FALSE, FALSE, 0);
    gtk_widget_show_all(row);
    scroll_to_bottom();
    return label;
}

static void clear_chat(GtkWidget *btn, gpointer data) {
    (void)btn;
    (void)data;
    if (streaming) return;
    GList *kids = gtk_container_get_children(GTK_CONTAINER(transcript));
    for (GList *l = kids; l; l = l->next) gtk_widget_destroy(GTK_WIDGET(l->data));
    g_list_free(kids);
    g_ptr_array_set_size(history, 0);
    add_hint(WELCOME);
}

static gboolean scroll_idle(gpointer data) {
    (void)data;
    if (vadj) {
#if GTK_MAJOR_VERSION >= 3
        gdouble bottom = gtk_adjustment_get_upper(vadj) - gtk_adjustment_get_page_size(vadj);
#else
        gdouble bottom = vadj->upper - vadj->page_size;
#endif
        if (bottom > 0) gtk_adjustment_set_value(vadj, bottom);
    }
    return FALSE;
}

static void scroll_to_bottom(void) {
    g_idle_add(scroll_idle, NULL);
}

/* --- keyboard ------------------------------------------------------------- */

static const char *kbd_rows[] = { "1234567890", "qwertyuiop", "asdfghjkl" };
static const char *kbd_row3 = "zxcvbnm";
static const char *sym_rows[] = { "!@#$%^&*()", "-_=+[]{}\\|", ";:'\"<>,.?/" };
static GPtrArray *kbd_letters; /* GtkButton* in the same order as the chars */
static GString *kbd_chars;
static gboolean shift_on;
static GtkWidget *kbd_letters_box, *kbd_symbols_box;

static void entry_insert(const char *s) {
    GtkEditable *ed = GTK_EDITABLE(entry);
    gint pos = gtk_editable_get_position(ed);
    gtk_editable_insert_text(ed, s, -1, &pos);
    gtk_editable_set_position(ed, pos);
}

static void entry_backspace(void) {
    GtkEditable *ed = GTK_EDITABLE(entry);
    gint pos = gtk_editable_get_position(ed);
    if (pos > 0) gtk_editable_delete_text(ed, pos - 1, pos);
}

static const char *shifted_char(char c, char buf[2]) {
    buf[0] = c;
    buf[1] = 0;
    if (!shift_on) return buf;
    if (c >= 'a' && c <= 'z') {
        buf[0] = (char)(c - 'a' + 'A');
        return buf;
    }
    const char *digits = "1234567890";
    const char *shifted = "!@#$%^&*()";
    const char *d = strchr(digits, c);
    if (d) {
        buf[0] = shifted[d - digits];
        return buf;
    }
    return buf;
}

static void apply_shift(void) {
    for (guint i = 0; i < kbd_letters->len; i++) {
        GtkWidget *btn = g_ptr_array_index(kbd_letters, i);
        char buf[2];
        gtk_button_set_label(GTK_BUTTON(btn), shifted_char(kbd_chars->str[i], buf));
    }
    if (shift_btn) gtk_button_set_label(GTK_BUTTON(shift_btn), shift_on ? "SHIFT" : "Shift");
}

static void keyboard_key(GtkWidget *btn, gpointer data) {
    const char *action = data;
    if (g_strcmp0(action, "shift") == 0) {
        shift_on = !shift_on;
        apply_shift();
        return;
    }
    if (g_strcmp0(action, "bksp") == 0) {
        entry_backspace();
        return;
    }
    if (g_strcmp0(action, "space") == 0) {
        entry_insert(" ");
        return;
    }
    if (g_strcmp0(action, "enter") == 0) {
        g_signal_emit_by_name(entry, "activate");
        return;
    }
    const char *label = gtk_button_get_label(GTK_BUTTON(btn));
    if (label) {
        entry_insert(label);
        /* one-shot shift, like a phone keyboard */
        if (shift_on) {
            shift_on = FALSE;
            apply_shift();
        }
    }
}

static void keyboard_layer(gboolean symbols) {
    widget_set_visible(kbd_letters_box, !symbols);
    widget_set_visible(kbd_symbols_box, symbols);
}

static void keyboard_toggle_layer(GtkWidget *btn, gpointer data) {
    (void)btn;
    (void)data;
    keyboard_layer(widget_is_visible(kbd_letters_box));
}

static GtkWidget *kbd_button(const char *label, const char *action, gboolean wide) {
    GtkWidget *btn = gtk_button_new_with_label(label);
    gtk_widget_set_size_request(btn, wide ? 200 : 40, 52);
    widget_set_id(btn, "chatui-key");
    g_signal_connect(btn, "clicked", G_CALLBACK(keyboard_key), (gpointer)action);
    return btn;
}

static GtkWidget *kbd_special(const char *label, const char *action) {
    GtkWidget *btn = gtk_button_new_with_label(label);
    gtk_widget_set_size_request(btn, 64, 52);
    widget_set_id(btn, "chatui-key");
    g_signal_connect(btn, "clicked", G_CALLBACK(keyboard_key), (gpointer)action);
    return btn;
}

static GtkWidget *kbd_row_from(const char *chars) {
    GtkWidget *row = box_new(GTK_ORIENTATION_HORIZONTAL, 2);
    for (const char *c = chars; *c; c++) {
        char label[2] = { *c, 0 };
        gtk_box_pack_start(GTK_BOX(row), kbd_button(label, "", FALSE), TRUE, TRUE, 0);
    }
    return row;
}

static GtkWidget *build_keyboard(void) {
    GtkWidget *box = box_new(GTK_ORIENTATION_VERTICAL, 2);
    widget_add_class(box, "keyboard");
    kbd_letters = g_ptr_array_new();
    kbd_chars = g_string_new(NULL);

    /* Letter layer */
    kbd_letters_box = box_new(GTK_ORIENTATION_VERTICAL, 2);
    for (guint r = 0; r < G_N_ELEMENTS(kbd_rows); r++) {
        GtkWidget *row = box_new(GTK_ORIENTATION_HORIZONTAL, 2);
        for (const char *c = kbd_rows[r]; *c; c++) {
            char label[2] = { *c, 0 };
            GtkWidget *btn = kbd_button(label, "", FALSE);
            g_ptr_array_add(kbd_letters, btn);
            g_string_append_c(kbd_chars, *c);
            gtk_box_pack_start(GTK_BOX(row), btn, TRUE, TRUE, 0);
        }
        gtk_box_pack_start(GTK_BOX(kbd_letters_box), row, TRUE, TRUE, 0);
    }
    GtkWidget *row3 = box_new(GTK_ORIENTATION_HORIZONTAL, 2);
    shift_btn = kbd_special("Shift", "shift");
    gtk_box_pack_start(GTK_BOX(row3), shift_btn, FALSE, FALSE, 0);
    for (const char *c = kbd_row3; *c; c++) {
        char label[2] = { *c, 0 };
        GtkWidget *btn = kbd_button(label, "", FALSE);
        g_ptr_array_add(kbd_letters, btn);
        g_string_append_c(kbd_chars, *c);
        gtk_box_pack_start(GTK_BOX(row3), btn, TRUE, TRUE, 0);
    }
    gtk_box_pack_start(GTK_BOX(row3), kbd_special("Bksp", "bksp"), FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(kbd_letters_box), row3, TRUE, TRUE, 0);

    GtkWidget *row4 = box_new(GTK_ORIENTATION_HORIZONTAL, 2);
    GtkWidget *sym_toggle = gtk_button_new_with_label("?123");
    gtk_widget_set_size_request(sym_toggle, 64, 52);
    widget_set_id(sym_toggle, "chatui-key");
    g_signal_connect(sym_toggle, "clicked", G_CALLBACK(keyboard_toggle_layer), NULL);
    gtk_box_pack_start(GTK_BOX(row4), sym_toggle, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(row4), kbd_button(",", "", FALSE), FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(row4), kbd_button("Space", "space", TRUE), TRUE, TRUE, 0);
    gtk_box_pack_start(GTK_BOX(row4), kbd_button(".", "", FALSE), FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(row4), kbd_button("Enter", "enter", FALSE), FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(kbd_letters_box), row4, TRUE, TRUE, 0);

    /* Symbols layer */
    kbd_symbols_box = box_new(GTK_ORIENTATION_VERTICAL, 2);
    for (guint r = 0; r < G_N_ELEMENTS(sym_rows); r++) {
        gtk_box_pack_start(GTK_BOX(kbd_symbols_box), kbd_row_from(sym_rows[r]), TRUE, TRUE, 0);
    }
    GtkWidget *srow4 = box_new(GTK_ORIENTATION_HORIZONTAL, 2);
    GtkWidget *abc_toggle = gtk_button_new_with_label("ABC");
    gtk_widget_set_size_request(abc_toggle, 64, 52);
    widget_set_id(abc_toggle, "chatui-key");
    g_signal_connect(abc_toggle, "clicked", G_CALLBACK(keyboard_toggle_layer), NULL);
    gtk_box_pack_start(GTK_BOX(srow4), abc_toggle, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(srow4), kbd_button(",", "", FALSE), FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(srow4), kbd_button("Space", "space", TRUE), TRUE, TRUE, 0);
    gtk_box_pack_start(GTK_BOX(srow4), kbd_button(".", "", FALSE), FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(srow4), kbd_special("Bksp", "bksp"), FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(kbd_symbols_box), srow4, TRUE, TRUE, 0);

    gtk_box_pack_start(GTK_BOX(box), kbd_letters_box, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(box), kbd_symbols_box, FALSE, FALSE, 0);
    widget_set_visible(kbd_symbols_box, FALSE);
    return box;
}

static void toggle_keyboard(GtkWidget *btn, gpointer data) {
    (void)btn;
    (void)data;
    widget_set_visible(kbd_box, !widget_is_visible(kbd_box));
}

/* --- server --------------------------------------------------------------- */

static gboolean run_capture(const char *cmd, char **out) {
    FILE *p = popen(cmd, "r");
    if (!p) return FALSE;
    GString *s = g_string_new(NULL);
    char buf[512];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, p)) > 0) g_string_append_len(s, buf, n);
    int status = pclose(p);
    if (out) *out = g_string_free(s, FALSE);
    else g_string_free(s, TRUE);
    return status == 0;
}

static gboolean server_healthy(void) {
    char *cmd = g_strdup_printf("curl -s --max-time 2 http://%s:%d/health", cfg.host, cfg.port);
    char *out = NULL;
    run_capture(cmd, &out);
    gboolean ok = out && strstr(out, "\"status\"") && strstr(out, "ok");
    g_free(cmd);
    g_free(out);
    return ok;
}

static char *find_model(void) {
    if (cfg.model) return g_strdup(cfg.model);
    char *dir = g_build_filename(cfg.app_dir, "model", NULL);
    GDir *d = g_dir_open(dir, 0, NULL);
    char *found = NULL;
    if (d) {
        const char *name;
        while ((name = g_dir_read_name(d))) {
            if (g_str_has_suffix(name, ".gguf") || g_str_has_suffix(name, ".GGUF")) {
                found = g_build_filename(dir, name, NULL);
                break;
            }
        }
        g_dir_close(d);
    }
    g_free(dir);
    return found;
}

static char *find_server_bin(void) {
    if (cfg.server_bin) return g_strdup(cfg.server_bin);
    char *local = g_build_filename(cfg.app_dir, "llama-server", NULL);
    char *found = NULL;
    if (g_file_test(local, G_FILE_TEST_IS_REGULAR)) {
        if (g_file_test(local, G_FILE_TEST_IS_EXECUTABLE)) {
            found = g_strdup(local);
        } else {
            /* vfat (or a strict mount) may not carry the x bit: run a copy
             * from /tmp, which always does. */
            gchar *tmp = g_strdup("/tmp/eink-chat-server-XXXXXX");
            gint fd = g_mkstemp(tmp);
            gchar *data = NULL;
            gsize len = 0;
            GError *err = NULL;
            if (fd >= 0 && g_file_get_contents(local, &data, &len, &err) &&
                g_file_set_contents(tmp, data, (gssize)len, &err)) {
                chmod(tmp, 0755);
                found = tmp;
                tmp = NULL;
            } else if (err) {
                g_error_free(err);
            }
            if (fd >= 0) close(fd);
            g_free(data);
            if (tmp) {
                g_unlink(tmp);
                g_free(tmp);
            }
        }
    } else {
        found = g_find_program_in_path("llama-server");
    }
    g_free(local);
    return found;
}

static gboolean have_lipc(void) {
    static int cached = -1;
    if (cached < 0) cached = g_find_program_in_path("lipc-set-prop") ? 1 : 0;
    return cached == 1;
}

static void reap_child(GPid pid, gint status, gpointer data) {
    (void)status;
    (void)data;
    g_spawn_close_pid(pid);
}

/* Fire and forget: a hung lipc-set-prop must never freeze the UI thread. */
static void run_async(const char *cmd) {
    gchar *argv[] = { "/bin/sh", "-c", (gchar *)cmd, NULL };
    GError *err = NULL;
    GPid pid = 0;
    if (g_spawn_async(NULL, argv, NULL, G_SPAWN_SEARCH_PATH | G_SPAWN_DO_NOT_REAP_CHILD,
                      NULL, NULL, &pid, &err)) {
        g_child_watch_add(pid, reap_child, NULL);
    } else if (err) {
        g_error_free(err);
    }
}

static void powerd_keepalive(gboolean on) {
    if (!have_lipc()) return;
    char *cmd = g_strdup_printf("lipc-set-prop com.lab126.powerd preventScreenSaver %d", on ? 1 : 0);
    run_async(cmd);
    g_free(cmd);
}

static void native_keyboard(gboolean open) {
    if (!cfg.native_kbd || !have_lipc()) return;
    char *cmd = open
        ? g_strdup_printf("lipc-set-prop com.lab126.keyboard open %s:abc:1", APP_ID)
        : g_strdup_printf("lipc-set-prop com.lab126.keyboard close %s", APP_ID);
    run_async(cmd);
    g_free(cmd);
}

static void set_status(const char *text) {
    if (status_label) gtk_label_set_text(GTK_LABEL(status_label), text ? text : "");
}

static void finish_turn(void);

static void on_server_exit(GPid pid, gint status, gpointer data) {
    (void)status;
    (void)data;
    g_spawn_close_pid(pid);
    server_ready = FALSE;
    server_spawned = FALSE;
    server_pid = 0;
    set_status("Server stopped");
    if (streaming) finish_turn();
}

static gboolean poll_health(gpointer data) {
    (void)data;
    if (server_healthy()) {
        server_ready = TRUE;
        set_status("Ready");
        gtk_widget_set_sensitive(send_btn, TRUE);
        return FALSE;
    }
    if (!server_spawned) {
        set_status("Offline");
        return FALSE;
    }
    if (++health_polls > 300) {
        set_status("Server failed");
        return FALSE;
    }
    return TRUE;
}

static void spawn_server(void) {
    char *model = find_model();
    char *bin = find_server_bin();
    g_print("chat-ui: app_dir=%s model=%s server=%s\n", cfg.app_dir,
            model ? model : "(none)", bin ? bin : "(none)");
    if (!bin || !model) {
        set_status(bin ? "no .gguf model found" : "no llama-server found");
        if (bin) g_free(bin);
        if (model) g_free(model);
        return;
    }
    GPtrArray *args = g_ptr_array_new();
    g_ptr_array_add(args, bin);
    g_ptr_array_add(args, "-m");
    g_ptr_array_add(args, model);
    g_ptr_array_add(args, "-c");
    g_ptr_array_add(args, "1024");
    g_ptr_array_add(args, "--host");
    g_ptr_array_add(args, cfg.host);
    char port[16];
    g_snprintf(port, sizeof port, "%d", cfg.port);
    g_ptr_array_add(args, "--port");
    g_ptr_array_add(args, port);
    gchar **extra = NULL;
    if (cfg.server_args) {
        extra = g_strsplit(cfg.server_args, " ", -1);
        for (gchar **p = extra; *p; p++) {
            if (**p) g_ptr_array_add(args, *p);
        }
    }
    g_ptr_array_add(args, NULL);

    GError *err = NULL;
    gboolean ok = g_spawn_async(NULL, (gchar **)args->pdata, NULL,
                                G_SPAWN_DO_NOT_REAP_CHILD | G_SPAWN_STDOUT_TO_DEV_NULL |
                                    G_SPAWN_STDERR_TO_DEV_NULL,
                                NULL, NULL, &server_pid, &err);
    if (extra) g_strfreev(extra);
    g_ptr_array_free(args, TRUE);
    if (!ok) {
        set_status("could not start llama-server");
        if (err) g_error_free(err);
        g_free(bin);
        g_free(model);
        return;
    }
    g_free(bin);
    g_free(model);
    server_spawned = TRUE;
    server_ready = FALSE;
    health_polls = 0;
    set_status("Starting...");
    g_print("chat-ui: llama-server started, pid %d\n", (int)server_pid);
    g_child_watch_add(server_pid, on_server_exit, NULL);
    g_timeout_add_seconds(1, poll_health, NULL);
}

static void backend_init(void) {
    if (server_healthy()) {
        server_ready = TRUE;
        set_status("Ready");
        gtk_widget_set_sensitive(send_btn, TRUE);
        g_print("chat-ui: server ready\n");
        return;
    }
    if (cfg.no_spawn) {
        set_status("Offline");
        return;
    }
    spawn_server();
}

/* --- the turn ------------------------------------------------------------- */

static void process_sse_line(const char *line) {
    if (!turn || !g_str_has_prefix(line, "data:")) return;
    const char *data = line + 5;
    while (*data == ' ') data++;
    if (g_str_has_prefix(data, "[DONE]")) return;

    if (strstr(data, "\"error\"")) {
        char *msg = sse_error_message(data);
        if (turn->answer->len == 0) {
            g_string_append_printf(turn->answer, "(server error: %s)", msg);
            gtk_label_set_text(GTK_LABEL(turn->bubble), turn->answer->str);
        }
        g_free(msg);
        return;
    }

    char *delta = sse_delta_content(data);
    if (delta) {
        g_string_append(turn->answer, delta);
        gtk_label_set_text(GTK_LABEL(turn->bubble), turn->answer->str);
        g_free(delta);
        scroll_to_bottom();
    }
}

static gboolean on_curl_out(GIOChannel *ch, GIOCondition cond, gpointer data) {
    (void)data;
    if (!turn) return FALSE;
    char buf[4096];
    gsize n = 0;
    GIOStatus st = g_io_channel_read_chars(ch, buf, sizeof buf, &n, NULL);
    for (gsize i = 0; i < n; i++) {
        if (buf[i] == '\n') {
            process_sse_line(turn->pending->str);
            g_string_truncate(turn->pending, 0);
        } else if (buf[i] != '\r') {
            g_string_append_c(turn->pending, buf[i]);
        }
    }
    if (st == G_IO_STATUS_EOF || (cond & (G_IO_HUP | G_IO_ERR))) {
        if (turn->out_ch) {
            g_io_channel_unref(turn->out_ch);
            turn->out_ch = NULL;
        }
        turn->out_watch = 0;
        return FALSE;
    }
    return TRUE;
}

static void on_curl_exit(GPid pid, gint status, gpointer data) {
    (void)status;
    (void)data;
    g_spawn_close_pid(pid);
    if (turn && turn->out_watch) {
        g_source_remove(turn->out_watch);
        turn->out_watch = 0;
    }
    if (turn && turn->out_ch) {
        g_io_channel_unref(turn->out_ch);
        turn->out_ch = NULL;
    }
    finish_turn();
}

static void finish_turn(void) {
    if (!turn) return;
    gboolean answered = turn->answer->len > 0;
    if (answered) add_history("assistant", turn->answer->str);
    else gtk_label_set_text(GTK_LABEL(turn->bubble), "(no answer)");

    if (turn->pending) g_string_free(turn->pending, TRUE);
    if (turn->answer) g_string_free(turn->answer, TRUE);
    if (turn->out_ch) {
        g_io_channel_unref(turn->out_ch);
        turn->out_ch = NULL;
    }
    if (turn->out_watch) {
        g_source_remove(turn->out_watch);
        turn->out_watch = 0;
    }
    if (turn->pid) {
        kill(turn->pid, SIGTERM);
        g_spawn_close_pid(turn->pid);
        turn->pid = 0;
    }
    g_free(turn);
    turn = NULL;
    streaming = FALSE;
    gtk_widget_set_sensitive(entry, TRUE);
    gtk_widget_set_sensitive(send_btn, TRUE);
    gtk_widget_set_sensitive(new_btn, TRUE);
    widget_set_visible(stop_btn, FALSE);
    set_status(server_ready ? "Ready" : "Offline");
    gtk_widget_grab_focus(entry);

    if (request_path) {
        g_unlink(request_path);
        g_free(request_path);
        request_path = NULL;
    }
    if (cfg.refresh_cmd && *cfg.refresh_cmd) {
        run_async(cfg.refresh_cmd);
    }
}

static void start_stream(GString *request) {
    request_path = NULL;
    int fd = g_file_open_tmp("eink-chat-XXXXXX.json", &request_path, NULL);
    if (fd < 0) {
        gtk_label_set_text(GTK_LABEL(turn->bubble), "(could not create the request file)");
        finish_turn();
        return;
    }
    if (write(fd, request->str, request->len) != (ssize_t)request->len) {
        close(fd);
        gtk_label_set_text(GTK_LABEL(turn->bubble), "(could not write the request)");
        finish_turn();
        return;
    }
    close(fd);

    char *url = g_strdup_printf("http://%s:%d/v1/chat/completions", cfg.host, cfg.port);
    char *data_arg = g_strdup_printf("@%s", request_path);
    const gchar *argv[] = { "curl", "-sN", "--max-time", "300",
                            "-H", "Content-Type: application/json",
                            "--data-binary", data_arg, url, NULL };
    gint out_fd = -1;
    GError *err = NULL;
    if (!g_spawn_async_with_pipes(NULL, (gchar **)argv, NULL,
                                  G_SPAWN_DO_NOT_REAP_CHILD | G_SPAWN_SEARCH_PATH,
                                  NULL, NULL, &turn->pid, NULL, &out_fd, NULL, &err)) {
        gtk_label_set_text(GTK_LABEL(turn->bubble), "(could not start curl)");
        g_error_free(err);
        g_free(url);
        g_free(data_arg);
        finish_turn();
        return;
    }
    g_free(url);
    g_free(data_arg);
    g_child_watch_add(turn->pid, on_curl_exit, NULL);
    turn->out_ch = g_io_channel_unix_new(out_fd);
    g_io_channel_set_encoding(turn->out_ch, NULL, NULL);
    turn->out_watch = g_io_add_watch(turn->out_ch, G_IO_IN | G_IO_HUP | G_IO_ERR, on_curl_out, NULL);
}

static void send_clicked(GtkWidget *btn, gpointer data) {
    (void)btn;
    (void)data;
    if (streaming) return;
    const char *text = gtk_entry_get_text(GTK_ENTRY(entry));
    if (!text || !*text) return;
    if (!server_ready) {
        set_status("Not ready");
        return;
    }
    gchar *message = g_strdup(text);
    add_bubble("user", message);
    add_history("user", message);
    g_free(message);
    gtk_entry_set_text(GTK_ENTRY(entry), "");

    turn = g_new0(Turn, 1);
    turn->answer = g_string_new(NULL);
    turn->pending = g_string_new(NULL);
    turn->bubble = add_bubble("bot", "");
    streaming = TRUE;
    gtk_widget_set_sensitive(entry, FALSE);
    gtk_widget_set_sensitive(send_btn, FALSE);
    gtk_widget_set_sensitive(new_btn, FALSE);
    widget_set_visible(stop_btn, TRUE);
    set_status("Writing...");

    GString *request = build_request();
    start_stream(request);
    g_string_free(request, TRUE);
}

static void stop_clicked(GtkWidget *btn, gpointer data) {
    (void)btn;
    (void)data;
    if (turn && turn->pid) kill(turn->pid, SIGTERM);
}

static void entry_activate(GtkEntry *e, gpointer data) {
    (void)e;
    (void)data;
    g_signal_emit_by_name(send_btn, "clicked");
}

/* --- window --------------------------------------------------------------- */

static void on_destroy(GtkWidget *w, gpointer data) {
    (void)w;
    (void)data;
    if (turn && turn->pid) kill(turn->pid, SIGTERM);
    if (server_spawned && server_pid) kill(server_pid, SIGTERM);
    native_keyboard(FALSE);
    powerd_keepalive(FALSE);
    gtk_main_quit();
}

static void build_ui(void) {
    load_style();

    window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    /* The Kindle's awesome WM only manages windows titled in the lab126
     * key-value format; a plain title leaves the app unmanaged and the panel
     * shows the white root window. PC:N asks for no chrome (no top bar). */
    gtk_window_set_title(GTK_WINDOW(window),
                         g_file_test("/mnt/us", G_FILE_TEST_IS_DIR)
                             ? "L:A_N:application_PC:N_ID:com.kumanaya.einkchat"
                             : "E-INK CHAT");
    gtk_window_set_default_size(GTK_WINDOW(window), 600, 800);
    if (!cfg.fullscreen) gtk_window_set_decorated(GTK_WINDOW(window), TRUE);

    GtkWidget *root = box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_container_add(GTK_CONTAINER(window), root);

    GtkWidget *header = gtk_event_box_new();
    style_header(header);
    widget_set_id(header, "chatui-header");
    GtkWidget *header_row = box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_container_add(GTK_CONTAINER(header), header_row);
    GtkWidget *title = gtk_label_new("Chat");
    gtk_box_pack_start(GTK_BOX(header_row), title, FALSE, FALSE, 0);
    status_label = gtk_label_new("Starting...");
    widget_add_class(status_label, "status");
    new_btn = gtk_button_new_with_label("New");
    gtk_widget_set_size_request(new_btn, 64, 44);
    widget_set_id(new_btn, "chatui-key");
    g_signal_connect(new_btn, "clicked", G_CALLBACK(clear_chat), NULL);
    gtk_box_pack_end(GTK_BOX(header_row), new_btn, FALSE, FALSE, 0);
    gtk_box_pack_end(GTK_BOX(header_row), status_label, FALSE, FALSE, 8);
    label_set_padding(title, 8, 6);
    label_set_padding(status_label, 8, 6);
    gtk_widget_set_size_request(header, -1, 46);
    widget_set_bold(title);
    widget_set_color(title, "#ffffff");
    widget_set_color(status_label, "#ffffff");
    gtk_box_pack_start(GTK_BOX(root), header, FALSE, FALSE, 0);

    transcript = box_new(GTK_ORIENTATION_VERTICAL, 2);
    scrolled = gtk_scrolled_window_new(NULL, NULL);
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scrolled), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
#if GTK_MAJOR_VERSION >= 3
    gtk_container_add(GTK_CONTAINER(scrolled), transcript);
#else
    /* GTK 2 will not take a plain box; it wants the viewport. */
    gtk_scrolled_window_add_with_viewport(GTK_SCROLLED_WINDOW(scrolled), transcript);
#endif
    vadj = gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(scrolled));
    gtk_box_pack_start(GTK_BOX(root), scrolled, TRUE, TRUE, 0);

    kbd_box = build_keyboard();
    gtk_box_pack_end(GTK_BOX(root), kbd_box, FALSE, FALSE, 0);

    GtkWidget *input = box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    widget_add_class(input, "composer");
    GtkWidget *kbd_toggle = gtk_button_new_with_label("Abc");
    gtk_widget_set_size_request(kbd_toggle, 56, 48);
    gtk_box_pack_start(GTK_BOX(input), kbd_toggle, FALSE, FALSE, 0);
    entry = gtk_entry_new();
    gtk_widget_set_name(entry, "entry");
#if GTK_MAJOR_VERSION >= 3
    gtk_entry_set_placeholder_text(GTK_ENTRY(entry), "Ask a question");
#endif
    gtk_box_pack_start(GTK_BOX(input), entry, TRUE, TRUE, 0);
    stop_btn = gtk_button_new_with_label("Stop");
    gtk_widget_set_size_request(stop_btn, 64, 48);
    widget_set_visible(stop_btn, FALSE);
    gtk_box_pack_start(GTK_BOX(input), stop_btn, FALSE, FALSE, 0);
    send_btn = gtk_button_new_with_label("Ask");
    gtk_widget_set_size_request(send_btn, 64, 48);
    gtk_widget_set_sensitive(send_btn, FALSE);
    gtk_box_pack_start(GTK_BOX(input), send_btn, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(root), input, FALSE, FALSE, 6);

    g_signal_connect(kbd_toggle, "clicked", G_CALLBACK(toggle_keyboard), NULL);
    g_signal_connect(entry, "activate", G_CALLBACK(entry_activate), NULL);
    g_signal_connect(send_btn, "clicked", G_CALLBACK(send_clicked), NULL);
    g_signal_connect(stop_btn, "clicked", G_CALLBACK(stop_clicked), NULL);
    g_signal_connect(window, "destroy", G_CALLBACK(on_destroy), NULL);
}

/* The backend starts after the first paint: the LIPC calls and the spawn are
 * synchronous, and doing them before gtk_main can leave a white window up. */
static gboolean start_backend(gpointer data) {
    (void)data;
    if (!cfg.keyboard_on) widget_set_visible(kbd_box, FALSE);
    keyboard_layer(FALSE);
    add_hint(WELCOME);
    native_keyboard(TRUE);
    powerd_keepalive(TRUE);
    backend_init();
    return FALSE;
}

/* --- self test ------------------------------------------------------------ */

static int run_self_test(void) {
    int failures = 0;
    GString *e = g_string_new(NULL);
    json_escape_append(e, "a\"b\\c\nd");
    if (strcmp(e->str, "a\\\"b\\\\c\\nd") != 0) {
        g_printerr("FAIL json_escape: %s\n", e->str);
        failures++;
    }
    g_string_free(e, TRUE);

    char *d = sse_delta_content("data: {\"choices\":[{\"delta\":{\"content\":\"Hel\\\"lo\"}}]}");
    if (!d || strcmp(d, "Hel\"lo") != 0) {
        g_printerr("FAIL sse_delta_content quote: %s\n", d ? d : "(null)");
        failures++;
    }
    g_free(d);

    d = sse_delta_content("data: {\"choices\":[{\"delta\":{\"content\":\"caf\\u00e9\"}}]}");
    if (!d || strcmp(d, "caf\xc3\xa9") != 0) {
        g_printerr("FAIL sse_delta_content unicode: %s\n", d ? d : "(null)");
        failures++;
    }
    g_free(d);

    if (sse_delta_content("data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}") != NULL) {
        g_printerr("FAIL sse_delta_content should ignore role-only deltas\n");
        failures++;
    }

    d = sse_error_message("data: {\"error\":{\"message\":\"model not found\"}}");
    if (!d || strcmp(d, "model not found") != 0) {
        g_printerr("FAIL sse_error_message: %s\n", d ? d : "(null)");
        failures++;
    }
    g_free(d);

    add_history("user", "hello \"kindle\"");
    GString *req = build_request();
    if (!strstr(req->str, "\"role\":\"system\"") || !strstr(req->str, "hello \\\"kindle\\\"")) {
        g_printerr("FAIL build_request: %s\n", req->str);
        failures++;
    }
    g_string_free(req, TRUE);

    if (failures == 0) g_print("self-test: ok\n");
    return failures == 0 ? 0 : 1;
}

/* --- main ----------------------------------------------------------------- */

int main(int argc, char **argv) {
    char *keyboard = NULL;
    gboolean show_version = FALSE;
    GOptionEntry options[] = {
        { "app-dir", 0, 0, G_OPTION_ARG_STRING, &cfg.app_dir, "Kindle app directory", "DIR" },
        { "host", 0, 0, G_OPTION_ARG_STRING, &cfg.host, "llama-server host", "H" },
        { "port", 0, 0, G_OPTION_ARG_INT, &cfg.port, "llama-server port", "N" },
        { "model", 0, 0, G_OPTION_ARG_STRING, &cfg.model, "path to a .gguf model", "FILE" },
        { "server-bin", 0, 0, G_OPTION_ARG_STRING, &cfg.server_bin, "path to llama-server", "FILE" },
        { "server-args", 0, 0, G_OPTION_ARG_STRING, &cfg.server_args, "extra llama-server arguments", "ARGS" },
        { "no-spawn", 0, 0, G_OPTION_ARG_NONE, &cfg.no_spawn, "never start llama-server", NULL },
        { "font-size", 0, 0, G_OPTION_ARG_INT, &cfg.font_size, "base font size", "N" },
        { "max-turns", 0, 0, G_OPTION_ARG_INT, &cfg.max_turns, "messages kept in the request", "N" },
        { "fullscreen", 0, 0, G_OPTION_ARG_NONE, &cfg.fullscreen, "fullscreen, undecorated", NULL },
        { "keyboard", 0, 0, G_OPTION_ARG_STRING, &keyboard, "start with the on-screen keyboard: on|off", "on|off" },
        { "native-keyboard", 0, 0, G_OPTION_ARG_NONE, &cfg.native_kbd, "ask the Kindle framework for its keyboard", NULL },
        { "refresh-cmd", 0, 0, G_OPTION_ARG_STRING, &cfg.refresh_cmd, "command run after each answer (e-ink refresh)", "CMD" },
        { "system", 0, 0, G_OPTION_ARG_STRING, &cfg.system, "system prompt", "TEXT" },
        { "self-test", 0, 0, G_OPTION_ARG_NONE, &cfg.self_test, "run the headless tests and exit", NULL },
        { "version", 0, 0, G_OPTION_ARG_NONE, &show_version, "print the version and exit", NULL },
        { NULL }
    };
    GOptionContext *ctx = g_option_context_new("- E-INK CHAT over llama-server");
    g_option_context_add_main_entries(ctx, options, NULL);
    GError *err = NULL;
    if (!g_option_context_parse(ctx, &argc, &argv, &err)) {
        g_printerr("chat-ui: %s\n", err->message);
        return 2;
    }
    g_option_context_free(ctx);

    if (show_version) {
        g_print("chat-ui %s (GTK %d)\n", CHATUI_VERSION, GTK_MAJOR_VERSION);
        return 0;
    }
    if (keyboard) cfg.keyboard_on = g_strcmp0(keyboard, "off") != 0;

    history = g_ptr_array_new_with_free_func(msg_free);

    if (cfg.self_test) return run_self_test();

    gtk_init(&argc, &argv);
    build_ui();
    gtk_widget_show_all(window);
    if (cfg.fullscreen) {
#if GTK_MAJOR_VERSION >= 3
        gtk_window_fullscreen(GTK_WINDOW(window));
#else
        /* kterm maximizes on the Kindle; EWMH fullscreen is not dependable
         * under the framework's awesome. */
        gtk_window_maximize(GTK_WINDOW(window));
#endif
    }

    g_idle_add(start_backend, NULL);

    gtk_main();
    g_ptr_array_free(history, TRUE);
    return 0;
}
