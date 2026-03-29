#define LCD_STATUS (*(volatile unsigned int *)0x80000000u)
#define LCD_CTRL   (*(volatile unsigned int *)0x80000004u)
#define LCD_TEXT   ((volatile unsigned char *)0x80000020u)

#define KBD_STATUS (*(volatile unsigned int *)0x80000080u)
#define KBD_DATA   (*(volatile unsigned int *)0x80000084u)

#define VGA_STATUS (*(volatile unsigned int *)0x80000100u)
#define VGA_TEXT   ((volatile unsigned char *)0x80001000u)

#define VGA_COLS 80u
#define VGA_ROWS 28u
#define LCD_COLS 16u
#define LCD_ROWS 2u

#define REPL_TOP 10u
#define PROMPT_COL 2u
#define INPUT_COL 7u
#define TEXT_MAX_COL 73u
#define LINE_MAX 192u
#define MAX_NAME_LEN 16u
#define MAX_GLOBAL_BINDINGS 24u
#define MAX_FRAME_BINDINGS 8u
#define MAX_PARAMS 4u
#define MAX_CLOSURES 16u
#define MAX_BODY_LEN 96u

enum EvalKind {
    EVAL_INT = 0,
    EVAL_CLOSURE = 1,
    EVAL_MSG = 2,
    EVAL_CLEAR = 3,
    EVAL_ERROR = 4
};

struct EvalResult {
    unsigned int kind;
    int value;
    unsigned int closure;
    const char *text;
};

struct EnvFrame {
    const struct EnvFrame *parent;
    unsigned int count;
    unsigned int capacity;
    char (*names)[MAX_NAME_LEN];
    unsigned int *kinds;
    int *values;
    unsigned int *closures;
};

struct Closure {
    unsigned int used;
    unsigned int param_count;
    char params[MAX_PARAMS][MAX_NAME_LEN];
    char body[MAX_BODY_LEN];
};

static const unsigned int DEC_POWERS[10] = {
    1000000000u, 100000000u, 10000000u, 1000000u, 100000u,
    10000u, 1000u, 100u, 10u, 1u
};

static char GLOBAL_NAMES[MAX_GLOBAL_BINDINGS][MAX_NAME_LEN];
static unsigned int GLOBAL_KINDS[MAX_GLOBAL_BINDINGS];
static int GLOBAL_VALUES[MAX_GLOBAL_BINDINGS];
static unsigned int GLOBAL_CLOSURES[MAX_GLOBAL_BINDINGS];
static unsigned int GLOBAL_COUNT = 0u;
static struct Closure CLOSURES[MAX_CLOSURES];
static char LAST_RESULT_NAME[MAX_NAME_LEN];

static void copy_name(char *dst, const char *src);

static void lcd_clear(void) {
    for (unsigned int i = 0; i < LCD_COLS * LCD_ROWS; ++i) {
        LCD_TEXT[i] = ' ';
    }
    LCD_CTRL = 1u;
}

static void lcd_putc(unsigned int row, unsigned int col, unsigned char ch) {
    unsigned int idx = (row << 4) + col;
    if (row < LCD_ROWS && col < LCD_COLS) {
        LCD_TEXT[idx] = ch;
    }
}

static void lcd_puts(unsigned int row, unsigned int col, const char *text) {
    while (*text != '\0' && row < LCD_ROWS && col < LCD_COLS) {
        lcd_putc(row, col, (unsigned char)*text);
        ++text;
        ++col;
    }
}

static void vga_clear(void) {
    for (unsigned int i = 0; i < VGA_COLS * VGA_ROWS; ++i) {
        VGA_TEXT[i] = ' ';
    }
}

static void vga_putc(unsigned int row, unsigned int col, unsigned char ch) {
    unsigned int idx = (row << 6) + (row << 4) + col;
    if (row < VGA_ROWS && col < VGA_COLS) {
        VGA_TEXT[idx] = ch;
    }
}

static void vga_puts(unsigned int row, unsigned int col, const char *text) {
    while (*text != '\0' && row < VGA_ROWS && col < VGA_COLS) {
        vga_putc(row, col, (unsigned char)*text);
        ++text;
        ++col;
    }
}

static void put_hex4_lcd(unsigned int row, unsigned int col, unsigned int value) {
    unsigned int nibble = value & 0xFu;
    lcd_putc(row, col, (unsigned char)(nibble < 10u ? ('0' + nibble) : ('A' + nibble - 10u)));
}

static void put_hex8_lcd(unsigned int row, unsigned int col, unsigned int value) {
    put_hex4_lcd(row, col + 0u, value >> 4);
    put_hex4_lcd(row, col + 1u, value >> 0);
}

static void draw_netx_logo(void) {
    static const char *logo[] = {
        " _   _      _  __  __",
        "| \\ | | ___| |_\\ \\/ /    _____ _____ _____ _____ ",
        "|  \\| |/ _ \\ __|\\  /    |   __|  _  |   __|  _  |",
        "| |\\  |  __/ |_ /  \\    |   __|   __|  |  |     |",
        "|_| \\_|\\___|\\__/_/\\_\\   |__|  |__|  |_____|__|__|"
    };

    for (unsigned int i = 0; i < 5u; ++i) {
        vga_puts(i, 1u, logo[i]);
    }
}

static void draw_shell_frame(void) {
    vga_puts(6u, PROMPT_COL, "NetX Scheme REPL");
    vga_puts(7u, PROMPT_COL, "Try: (define x 7) (if (> x 3) 1 0) ((lambda (y) (+ y x)) 5)");
}

static void draw_lcd_header(void) {
    lcd_puts(0u, 0u, "RAW:");
    lcd_puts(0u, 9u, "CH:");
    lcd_puts(1u, 0u, "CNT:");
    lcd_puts(1u, 9u, "SBE:");
}

static void lcd_update_status(unsigned int last_scan, unsigned int typed_count,
                              unsigned int last_char, unsigned int shift_down, unsigned int break_code,
                              unsigned int extended_code) {
    put_hex8_lcd(0u, 4u, last_scan);
    put_hex8_lcd(0u, 12u, last_char);
    put_hex8_lcd(1u, 4u, typed_count);
    lcd_putc(1u, 13u,    shift_down ? '1' : '0');
    lcd_putc(1u, 14u,    break_code ? '1' : '0');
    lcd_putc(1u, 15u, extended_code ? '1' : '0');
}

static void clear_repl_region(void) {
    for (unsigned int row = REPL_TOP; row < VGA_ROWS; ++row) {
        for (unsigned int col = PROMPT_COL; col <= TEXT_MAX_COL; ++col) {
            vga_putc(row, col, ' ');
        }
    }
}

static void repl_newline(unsigned int *cursor_row, unsigned int *cursor_col) {
    *cursor_col = PROMPT_COL;
    if (*cursor_row < VGA_ROWS - 1u) {
        *cursor_row += 1u;
        return;
    }

    for (unsigned int row = REPL_TOP; row < VGA_ROWS - 1u; ++row) {
        for (unsigned int col = PROMPT_COL; col <= TEXT_MAX_COL; ++col) {
            unsigned int from = ((row + 1u) << 6) + ((row + 1u) << 4) + col;
            unsigned int to = (row << 6) + (row << 4) + col;
            VGA_TEXT[to] = VGA_TEXT[from];
        }
    }

    for (unsigned int col = PROMPT_COL; col <= TEXT_MAX_COL; ++col) {
        vga_putc(VGA_ROWS - 1u, col, ' ');
    }
}

static void console_putc(unsigned char ch, unsigned int *cursor_row, unsigned int *cursor_col) {
    if (ch == '\n') {
        repl_newline(cursor_row, cursor_col);
        return;
    }
    if (*cursor_col > TEXT_MAX_COL) {
        repl_newline(cursor_row, cursor_col);
    }
    vga_putc(*cursor_row, *cursor_col, ch);
    *cursor_col += 1u;
}

static void console_puts(const char *text, unsigned int *cursor_row, unsigned int *cursor_col) {
    while (*text != '\0') {
        console_putc((unsigned char)*text, cursor_row, cursor_col);
        ++text;
    }
}

static void print_prompt(unsigned int *cursor_row, unsigned int *cursor_col) {
    *cursor_col = PROMPT_COL;
    vga_puts(*cursor_row, PROMPT_COL, "scm> ");
    *cursor_col = INPUT_COL;
}

static void print_cont_prompt(unsigned int row) {
    vga_puts(row, PROMPT_COL, ".... ");
}

static void copy_line(char *dst, const char *src, unsigned int max_len) {
    unsigned int i = 0u;
    while (i < max_len && src[i] != '\0') {
        dst[i] = src[i];
        ++i;
    }
    dst[i] = '\0';
}

static unsigned int unmatched_paren_count(const char *line, unsigned int line_len) {
    unsigned int depth = 0u;
    for (unsigned int i = 0u; i < line_len; ++i) {
        if (line[i] == '(') {
            depth += 1u;
        } else if (line[i] == ')' && depth > 0u) {
            depth -= 1u;
        }
    }
    return depth;
}

static void input_cursor_position(unsigned int start_row, const char *line, unsigned int line_len,
                                  unsigned int cursor_index, unsigned int *cursor_row,
                                  unsigned int *cursor_col) {
    unsigned int row = start_row;
    unsigned int col = INPUT_COL;

    if (cursor_index > line_len) {
        cursor_index = line_len;
    }

    for (unsigned int i = 0u; i < cursor_index; ++i) {
        if (line[i] == '\n') {
            row += 1u;
            if (row >= VGA_ROWS) {
                row = VGA_ROWS - 1u;
            }
            col = INPUT_COL;
            continue;
        }

        col += 1u;
        if (col > TEXT_MAX_COL) {
            row += 1u;
            if (row >= VGA_ROWS) {
                row = VGA_ROWS - 1u;
            }
            col = INPUT_COL;
        }
    }

    *cursor_row = row;
    *cursor_col = col;
}

static unsigned int input_end_row(unsigned int start_row, const char *line, unsigned int line_len) {
    unsigned int row = start_row;
    unsigned int col = INPUT_COL;

    for (unsigned int i = 0u; i < line_len; ++i) {
        if (line[i] == '\n') {
            row += 1u;
            if (row >= VGA_ROWS) {
                return VGA_ROWS - 1u;
            }
            col = INPUT_COL;
            continue;
        }

        col += 1u;
        if (col > TEXT_MAX_COL) {
            row += 1u;
            if (row >= VGA_ROWS) {
                return VGA_ROWS - 1u;
            }
            col = INPUT_COL;
        }
    }

    return row;
}

static void redraw_input_line(unsigned int start_row, const char *line, unsigned int line_len,
                              unsigned int cursor_index, unsigned int cursor_visible) {
    unsigned int row = start_row;
    unsigned int col = INPUT_COL;
    unsigned int cursor_row = start_row;
    unsigned int cursor_col = INPUT_COL;
    unsigned int current_end_row = input_end_row(start_row, line, line_len);
    static unsigned int last_start_row = REPL_TOP;
    static unsigned int last_end_row = REPL_TOP;
    unsigned int clear_end_row = current_end_row;

    if (start_row == last_start_row && last_end_row > clear_end_row) {
        clear_end_row = last_end_row;
    }

    for (unsigned int clear_row = start_row; clear_row <= clear_end_row; ++clear_row) {
        for (unsigned int clear_col = PROMPT_COL; clear_col <= TEXT_MAX_COL; ++clear_col) {
            vga_putc(clear_row, clear_col, ' ');
        }
    }

    print_prompt(&row, &col);
    row = start_row;
    col = INPUT_COL;

    for (unsigned int i = 0u; i < line_len; ++i) {
        if (i == cursor_index) {
            cursor_row = row;
            cursor_col = col;
        }

        if (line[i] == '\n') {
            row += 1u;
            if (row >= VGA_ROWS) {
                row = VGA_ROWS - 1u;
            }
            print_cont_prompt(row);
            col = INPUT_COL;
            continue;
        }

        vga_putc(row, col, (unsigned char)line[i]);
        col += 1u;
        if (col > TEXT_MAX_COL) {
            row += 1u;
            if (row >= VGA_ROWS) {
                row = VGA_ROWS - 1u;
            }
            print_cont_prompt(row);
            col = INPUT_COL;
        }
    }

    if (cursor_index >= line_len) {
        cursor_row = row;
        cursor_col = col;
    }

    if (cursor_visible && cursor_row < VGA_ROWS && cursor_col <= TEXT_MAX_COL) {
        vga_putc(cursor_row, cursor_col, '_');
    }

    last_start_row = start_row;
    last_end_row = current_end_row;
}

static void put_hex_byte_vga(unsigned int row, unsigned int col, unsigned int value) {
    unsigned int hi = (value >> 4) & 0xFu;
    unsigned int lo = value & 0xFu;
    vga_putc(row, col + 0u, (unsigned char)(hi < 10u ? ('0' + hi) : ('A' + hi - 10u)));
    vga_putc(row, col + 1u, (unsigned char)(lo < 10u ? ('0' + lo) : ('A' + lo - 10u)));
}

static unsigned int decode_set2(unsigned int code, unsigned int shift_down, unsigned int caps_lock) {
    unsigned int upper = shift_down ^ caps_lock;

    if (code == 0x1Cu) return upper ? 'A' : 'a';
    if (code == 0x32u) return upper ? 'B' : 'b';
    if (code == 0x21u) return upper ? 'C' : 'c';
    if (code == 0x23u) return upper ? 'D' : 'd';
    if (code == 0x24u) return upper ? 'E' : 'e';
    if (code == 0x2Bu) return upper ? 'F' : 'f';
    if (code == 0x34u) return upper ? 'G' : 'g';
    if (code == 0x33u) return upper ? 'H' : 'h';
    if (code == 0x43u) return upper ? 'I' : 'i';
    if (code == 0x3Bu) return upper ? 'J' : 'j';
    if (code == 0x42u) return upper ? 'K' : 'k';
    if (code == 0x4Bu) return upper ? 'L' : 'l';
    if (code == 0x3Au) return upper ? 'M' : 'm';
    if (code == 0x31u) return upper ? 'N' : 'n';
    if (code == 0x44u) return upper ? 'O' : 'o';
    if (code == 0x4Du) return upper ? 'P' : 'p';
    if (code == 0x15u) return upper ? 'Q' : 'q';
    if (code == 0x2Du) return upper ? 'R' : 'r';
    if (code == 0x1Bu) return upper ? 'S' : 's';
    if (code == 0x2Cu) return upper ? 'T' : 't';
    if (code == 0x3Cu) return upper ? 'U' : 'u';
    if (code == 0x2Au) return upper ? 'V' : 'v';
    if (code == 0x1Du) return upper ? 'W' : 'w';
    if (code == 0x22u) return upper ? 'X' : 'x';
    if (code == 0x35u) return upper ? 'Y' : 'y';
    if (code == 0x1Au) return upper ? 'Z' : 'z';

    if (code == 0x45u) return shift_down ? ')' : '0';
    if (code == 0x16u) return shift_down ? '!' : '1';
    if (code == 0x1Eu) return shift_down ? '@' : '2';
    if (code == 0x26u) return shift_down ? '#' : '3';
    if (code == 0x25u) return shift_down ? '$' : '4';
    if (code == 0x2Eu) return shift_down ? '%' : '5';
    if (code == 0x36u) return shift_down ? '^' : '6';
    if (code == 0x3Du) return shift_down ? '&' : '7';
    if (code == 0x3Eu) return shift_down ? '*' : '8';
    if (code == 0x46u) return shift_down ? '(' : '9';
    if (code == 0x29u) return 0x20u;
    if (code == 0x5Au) return 0x0Au;
    if (code == 0x66u) return 0x08u;
    if (code == 0x0Du) return 0x09u;
    if (code == 0x4Eu) return shift_down ? '_' : '-';
    if (code == 0x55u) return shift_down ? '+' : '=';
    if (code == 0x54u) return shift_down ? '{' : '[';
    if (code == 0x5Bu) return shift_down ? '}' : ']';
    if (code == 0x5Du) return shift_down ? '|' : '\\';
    if (code == 0x4Cu) return shift_down ? ':' : ';';
    if (code == 0x52u) return shift_down ? '"' : '\'';
    if (code == 0x41u) return shift_down ? '<' : ',';
    if (code == 0x49u) return shift_down ? '>' : '.';
    if (code == 0x4Au) return shift_down ? '?' : '/';
    if (code == 0x0Eu) return shift_down ? '~' : '`';

    return 0u;
}

static int is_space(char ch) {
    return ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r';
}

static int is_digit(char ch) {
    return ch >= '0' && ch <= '9';
}

static void skip_ws(const char **p) {
    while (is_space(**p)) {
        ++(*p);
    }
}

static int streq(const char *a, const char *b) {
    while (*a != '\0' && *b != '\0') {
        if (*a != *b) {
            return 0;
        }
        ++a;
        ++b;
    }
    return *a == '\0' && *b == '\0';
}

static void copy_name(char *dst, const char *src) {
    unsigned int i = 0u;
    while (src[i] != '\0' && i + 1u < MAX_NAME_LEN) {
        dst[i] = src[i];
        ++i;
    }
    dst[i] = '\0';
}

static int env_lookup(const struct EnvFrame *env, const char *name, struct EvalResult *out) {
    while (env != 0) {
        for (unsigned int i = 0; i < env->count; ++i) {
            if (streq(env->names[i], name)) {
                out->kind = env->kinds[i];
                out->value = env->values[i];
                out->closure = env->closures[i];
                out->text = "";
                return 1;
            }
        }
        env = env->parent;
    }
    return 0;
}

static int env_bind(struct EnvFrame *env, const char *name, struct EvalResult value) {
    for (unsigned int i = 0; i < env->count; ++i) {
        if (streq(env->names[i], name)) {
            env->kinds[i] = value.kind;
            env->values[i] = value.value;
            env->closures[i] = value.closure;
            return 1;
        }
    }
    if (env->count >= env->capacity) {
        return 0;
    }
    copy_name(env->names[env->count], name);
    env->kinds[env->count] = value.kind;
    env->values[env->count] = value.value;
    env->closures[env->count] = value.closure;
    env->count += 1u;
    return 1;
}

static int global_lookup(const char *name, struct EvalResult *out) {
    for (unsigned int i = 0; i < GLOBAL_COUNT; ++i) {
        if (streq(GLOBAL_NAMES[i], name)) {
            out->kind = GLOBAL_KINDS[i];
            out->value = GLOBAL_VALUES[i];
            out->closure = GLOBAL_CLOSURES[i];
            out->text = "";
            return 1;
        }
    }
    return 0;
}

static int global_bind(const char *name, struct EvalResult value) {
    for (unsigned int i = 0; i < GLOBAL_COUNT; ++i) {
        if (streq(GLOBAL_NAMES[i], name)) {
            GLOBAL_KINDS[i] = value.kind;
            GLOBAL_VALUES[i] = value.value;
            GLOBAL_CLOSURES[i] = value.closure;
            return 1;
        }
    }
    if (GLOBAL_COUNT >= MAX_GLOBAL_BINDINGS) {
        return 0;
    }
    copy_name(GLOBAL_NAMES[GLOBAL_COUNT], name);
    GLOBAL_KINDS[GLOBAL_COUNT] = value.kind;
    GLOBAL_VALUES[GLOBAL_COUNT] = value.value;
    GLOBAL_CLOSURES[GLOBAL_COUNT] = value.closure;
    GLOBAL_COUNT += 1u;
    return 1;
}

static struct EvalResult make_int_result(int value) {
    struct EvalResult result;
    result.kind = EVAL_INT;
    result.value = value;
    result.closure = 0u;
    result.text = "";
    return result;
}

static struct EvalResult make_closure_result(unsigned int closure) {
    struct EvalResult result;
    result.kind = EVAL_CLOSURE;
    result.value = 0;
    result.closure = closure;
    result.text = "";
    return result;
}

static struct EvalResult make_msg_result(const char *text) {
    struct EvalResult result;
    result.kind = EVAL_MSG;
    result.value = 0;
    result.closure = 0u;
    result.text = text;
    return result;
}

static struct EvalResult make_name_result(const char *name) {
    copy_name(LAST_RESULT_NAME, name);
    return make_msg_result(LAST_RESULT_NAME);
}

static struct EvalResult make_error_result(const char *text) {
    struct EvalResult result;
    result.kind = EVAL_ERROR;
    result.value = 0;
    result.closure = 0u;
    result.text = text;
    return result;
}

static struct EvalResult make_clear_result(void) {
    struct EvalResult result;
    result.kind = EVAL_CLEAR;
    result.value = 0;
    result.closure = 0u;
    result.text = "";
    return result;
}

static const char *scan_expr_end(const char *s) {
    unsigned int depth = 0u;
    while (*s != '\0') {
        if (*s == '(') {
            depth += 1u;
        } else if (*s == ')') {
            if (depth == 0u) {
                return s;
            }
            depth -= 1u;
            if (depth == 0u) {
                return s + 1;
            }
        } else if (depth == 0u && is_space(*s)) {
            return s;
        }
        ++s;
    }
    return s;
}

static int mul_int(int a, int b) {
    int negative = 0;
    int result = 0;

    if (a < 0) {
        a = -a;
        negative = !negative;
    }
    if (b < 0) {
        b = -b;
        negative = !negative;
    }

    while (b > 0) {
        if ((b & 1) != 0) {
            result += a;
        }
        a <<= 1;
        b >>= 1;
    }

    return negative ? -result : result;
}

int __mulsi3(int a, int b) {
    return mul_int(a, b);
}

static void parse_ident(const char **p, char *buf, unsigned int max_len) {
    unsigned int len = 0u;
    while (**p != '\0' && !is_space(**p) && **p != '(' && **p != ')' && len + 1u < max_len) {
        buf[len++] = **p;
        ++(*p);
    }
    buf[len] = '\0';
}

static int parse_param_list(const char **p, char params[MAX_PARAMS][MAX_NAME_LEN], unsigned int *count) {
    *count = 0u;
    skip_ws(p);
    if (**p != '(') {
        return 0;
    }
    ++(*p);
    while (1) {
        char ident[MAX_NAME_LEN];
        skip_ws(p);
        if (**p == ')') {
            ++(*p);
            return 1;
        }
        if (**p == '\0' || *count >= MAX_PARAMS) {
            return 0;
        }
        parse_ident(p, ident, sizeof(ident));
        if (ident[0] == '\0') {
            return 0;
        }
        copy_name(params[*count], ident);
        *count += 1u;
    }
}

static int alloc_closure(char params[MAX_PARAMS][MAX_NAME_LEN], unsigned int param_count,
                         const char *body_start, const char *body_end, unsigned int *closure_out) {
    for (unsigned int i = 0; i < MAX_CLOSURES; ++i) {
        if (!CLOSURES[i].used) {
            unsigned int len = 0u;
            CLOSURES[i].used = 1u;
            CLOSURES[i].param_count = param_count;
            for (unsigned int j = 0; j < param_count; ++j) {
                copy_name(CLOSURES[i].params[j], params[j]);
            }
            while (body_start + len < body_end && len + 1u < MAX_BODY_LEN) {
                CLOSURES[i].body[len] = body_start[len];
                ++len;
            }
            CLOSURES[i].body[len] = '\0';
            *closure_out = i;
            return 1;
        }
    }
    return 0;
}

static int parse_int_literal(const char **p, int *out) {
    int sign = 1;
    int value = 0;
    const char *s = *p;

    if (*s == '-') {
        sign = -1;
        ++s;
    } else if (*s == '+') {
        ++s;
    }

    if (!is_digit(*s)) {
        return 0;
    }

    while (is_digit(*s)) {
        value = (value << 3) + (value << 1) + (*s - '0');
        ++s;
    }

    *p = s;
    *out = sign < 0 ? -value : value;
    return 1;
}

static struct EvalResult eval_expr(const char **p, const struct EnvFrame *env, unsigned int depth);

static int apply_builtin(const char *name, int *args, unsigned int argc, struct EvalResult *out) {
    int acc = 0;

    if (streq(name, "+")) {
        for (unsigned int i = 0; i < argc; ++i) {
            acc += args[i];
        }
        *out = make_int_result(acc);
        return 1;
    }

    if (streq(name, "*")) {
        acc = 1;
        for (unsigned int i = 0; i < argc; ++i) {
            acc = mul_int(acc, args[i]);
        }
        *out = make_int_result(argc == 0u ? 1 : acc);
        return 1;
    }

    if (streq(name, "-")) {
        if (argc == 0u) {
            *out = make_error_result("missing arg");
            return 1;
        }
        acc = args[0];
        if (argc == 1u) {
            *out = make_int_result(-acc);
            return 1;
        }
        for (unsigned int i = 1; i < argc; ++i) {
            acc -= args[i];
        }
        *out = make_int_result(acc);
        return 1;
    }

    if (streq(name, "=") || streq(name, "<") || streq(name, ">")) {
        if (argc != 2u) {
            *out = make_error_result("need 2 args");
            return 1;
        }
        if (streq(name, "=")) {
            *out = make_int_result(args[0] == args[1] ? 1 : 0);
        } else if (streq(name, "<")) {
            *out = make_int_result(args[0] < args[1] ? 1 : 0);
        } else {
            *out = make_int_result(args[0] > args[1] ? 1 : 0);
        }
        return 1;
    }

    return 0;
}

static int is_builtin_name(const char *name) {
    return streq(name, "+") || streq(name, "-") || streq(name, "*") ||
           streq(name, "=") || streq(name, "<") || streq(name, ">");
}

static struct EvalResult eval_closure(unsigned int closure_index, struct EvalResult *args,
                                      unsigned int argc, const struct EnvFrame *env,
                                      unsigned int depth) {
    char local_names[MAX_FRAME_BINDINGS][MAX_NAME_LEN];
    unsigned int local_kinds[MAX_FRAME_BINDINGS];
    int local_values[MAX_FRAME_BINDINGS];
    unsigned int local_closures[MAX_FRAME_BINDINGS];
    struct EnvFrame local_env;
    const char *body_p;
    struct EvalResult result;

    if (closure_index >= MAX_CLOSURES || !CLOSURES[closure_index].used) {
        return make_error_result("bad closure");
    }
    if (CLOSURES[closure_index].param_count != argc) {
        return make_error_result("arg mismatch");
    }
    if (argc > MAX_FRAME_BINDINGS) {
        return make_error_result("too many args");
    }

    local_env.parent = env;
    local_env.count = 0u;
    local_env.capacity = MAX_FRAME_BINDINGS;
    local_env.names = local_names;
    local_env.kinds = local_kinds;
    local_env.values = local_values;
    local_env.closures = local_closures;

    for (unsigned int i = 0; i < argc; ++i) {
        if (!env_bind(&local_env, CLOSURES[closure_index].params[i], args[i])) {
            return make_error_result("frame full");
        }
    }

    body_p = CLOSURES[closure_index].body;
    result = eval_expr(&body_p, &local_env, depth + 1u);
    skip_ws(&body_p);
    if (*body_p != '\0' && result.kind != EVAL_ERROR) {
        return make_error_result("body trailing");
    }
    return result;
}

static struct EvalResult eval_list(const char **p, const struct EnvFrame *env, unsigned int depth) {
    char op[MAX_NAME_LEN];
    struct EvalResult func;
    struct EvalResult args[MAX_PARAMS];
    int int_args[MAX_PARAMS];
    unsigned int argc = 0u;
    unsigned int use_builtin = 0u;
    char builtin_name[MAX_NAME_LEN];

    ++(*p);
    skip_ws(p);

    if (**p != '(') {
        parse_ident(p, op, sizeof(op));
        if (op[0] == '\0') {
            return make_error_result("empty form");
        }

        if (streq(op, "help")) {
            skip_ws(p);
            if (**p == ')') {
                ++(*p);
                return make_msg_result("(define ...), (if ...), (lambda ...), (+ ...)");
            }
        }

        if (streq(op, "about")) {
            skip_ws(p);
            if (**p == ')') {
                ++(*p);
                return make_msg_result("NetX Scheme on RV32I");
            }
        }

        if (streq(op, "clear")) {
            skip_ws(p);
            if (**p == ')') {
                ++(*p);
                return make_clear_result();
            }
        }

        if (streq(op, "if")) {
            struct EvalResult cond;
            const char *then_start;
            const char *then_end;
            const char *else_start;
            const char *else_end;
            const char *branch_p;

            cond = eval_expr(p, env, depth + 1u);
            if (cond.kind != EVAL_INT) {
                return cond.kind == EVAL_ERROR ? cond : make_error_result("bad cond");
            }
            skip_ws(p);
            then_start = *p;
            then_end = scan_expr_end(then_start);
            *p = then_end;
            skip_ws(p);
            else_start = *p;
            else_end = scan_expr_end(else_start);
            *p = else_end;
            skip_ws(p);
            if (**p != ')') {
                return make_error_result("missing )");
            }
            ++(*p);
            branch_p = cond.value != 0 ? then_start : else_start;
            return eval_expr(&branch_p, env, depth + 1u);
        }

        if (streq(op, "lambda")) {
            char params[MAX_PARAMS][MAX_NAME_LEN];
            unsigned int param_count = 0u;
            const char *body_start;
            const char *body_end;
            unsigned int closure_index;

            if (!parse_param_list(p, params, &param_count)) {
                return make_error_result("bad params");
            }
            skip_ws(p);
            body_start = *p;
            body_end = scan_expr_end(body_start);
            *p = body_end;
            skip_ws(p);
            if (**p != ')') {
                return make_error_result("missing )");
            }
            ++(*p);
            if (!alloc_closure(params, param_count, body_start, body_end, &closure_index)) {
                return make_error_result("closure full");
            }
            return make_closure_result(closure_index);
        }

        if (streq(op, "define")) {
            skip_ws(p);
            if (**p == '(') {
                char params[MAX_PARAMS][MAX_NAME_LEN];
                unsigned int param_count = 0u;
                char fn_name[MAX_NAME_LEN];
                const char *body_start;
                const char *body_end;
                unsigned int closure_index;
                struct EvalResult value;

                ++(*p);
                skip_ws(p);
                parse_ident(p, fn_name, sizeof(fn_name));
                if (fn_name[0] == '\0' || !parse_param_list(p, params, &param_count)) {
                    return make_error_result("bad define");
                }
                skip_ws(p);
                body_start = *p;
                body_end = scan_expr_end(body_start);
                *p = body_end;
                skip_ws(p);
                if (**p != ')') {
                    return make_error_result("missing )");
                }
                ++(*p);
                if (!alloc_closure(params, param_count, body_start, body_end, &closure_index)) {
                    return make_error_result("closure full");
                }
                value = make_closure_result(closure_index);
                if (!global_bind(fn_name, value)) {
                    return make_error_result("define full");
                }
                return make_name_result(fn_name);
            } else {
                char name[MAX_NAME_LEN];
                struct EvalResult value;

                parse_ident(p, name, sizeof(name));
                if (name[0] == '\0') {
                    return make_error_result("bad define");
                }
                value = eval_expr(p, env, depth + 1u);
                if (value.kind == EVAL_ERROR || value.kind == EVAL_MSG || value.kind == EVAL_CLEAR) {
                    return value;
                }
                skip_ws(p);
                if (**p != ')') {
                    return make_error_result("missing )");
                }
                ++(*p);
                if (!global_bind(name, value)) {
                    return make_error_result("define full");
                }
                return make_name_result(name);
            }
        }

        if (is_builtin_name(op)) {
            copy_name(builtin_name, op);
            use_builtin = 1u;
        } else {
            if (!env_lookup(env, op, &func) && !global_lookup(op, &func)) {
                return make_error_result("unknown form");
            }
        }
    } else {
        func = eval_expr(p, env, depth + 1u);
        if (func.kind == EVAL_ERROR) {
            return func;
        }
    }

    while (1) {
        struct EvalResult arg;
        skip_ws(p);
        if (**p == ')') {
            ++(*p);
            break;
        }
        if (**p == '\0' || argc >= MAX_PARAMS) {
            return make_error_result("args bad");
        }
        arg = eval_expr(p, env, depth + 1u);
        if (arg.kind == EVAL_ERROR || arg.kind == EVAL_MSG || arg.kind == EVAL_CLEAR) {
            return arg;
        }
        args[argc] = arg;
        if (arg.kind == EVAL_INT) {
            int_args[argc] = arg.value;
        }
        argc += 1u;
    }

    if (use_builtin) {
        for (unsigned int i = 0; i < argc; ++i) {
            if (args[i].kind != EVAL_INT) {
                return make_error_result("builtin arg");
            }
        }
        if (!apply_builtin(builtin_name, int_args, argc, &func)) {
            return make_error_result("unknown builtin");
        }
        return func;
    }

    if (func.kind == EVAL_CLOSURE) {
        return eval_closure(func.closure, args, argc, env, depth);
    }
    return make_error_result("not callable");
}

static struct EvalResult eval_expr(const char **p, const struct EnvFrame *env, unsigned int depth) {
    char ident[MAX_NAME_LEN];
    int value;
    struct EvalResult result;

    if (depth > 48u) {
        return make_error_result("too deep");
    }

    skip_ws(p);
    if (**p == '(') {
        return eval_list(p, env, depth);
    }

    if (parse_int_literal(p, &value)) {
        return make_int_result(value);
    }

    parse_ident(p, ident, sizeof(ident));
    if (ident[0] == '\0') {
        return make_error_result("bad atom");
    }
    if (streq(ident, "#t")) {
        return make_int_result(1);
    }
    if (streq(ident, "#f")) {
        return make_int_result(0);
    }
    if (streq(ident, "answer")) {
        return make_int_result(42);
    }
    if (streq(ident, "help")) {
        return make_msg_result("try define, if, lambda, +, -, *, =, <, >");
    }
    if (env_lookup(env, ident, &result) || global_lookup(ident, &result)) {
        return result;
    }
    return make_error_result("bad atom");
}

static void print_int10(int value, unsigned int *row, unsigned int *col) {
    unsigned int magnitude;
    unsigned int started = 0u;

    if (value < 0) {
        console_putc('-', row, col);
        magnitude = (unsigned int)(-value);
    } else {
        magnitude = (unsigned int)value;
    }

    for (unsigned int i = 0; i < 10u; ++i) {
        unsigned int digit = 0u;
        while (magnitude >= DEC_POWERS[i]) {
            magnitude -= DEC_POWERS[i];
            ++digit;
        }
        if (digit != 0u || started || DEC_POWERS[i] == 1u) {
            console_putc((unsigned char)('0' + digit), row, col);
            started = 1u;
        }
    }
}

static void run_line(const char *line, unsigned int *row, unsigned int *col) {
    const char *p = line;
    struct EvalResult result = eval_expr(&p, 0, 0u);
    skip_ws(&p);
    if (*p != '\0' && result.kind != EVAL_ERROR) {
        result.kind = EVAL_ERROR;
        result.text = "trailing text";
    }

    if (result.kind == EVAL_CLEAR) {
        vga_clear();
        draw_netx_logo();
        draw_shell_frame();
        *row = REPL_TOP;
        *col = PROMPT_COL;
        return;
    }

    repl_newline(row, col);
    if (result.kind == EVAL_INT) {
        print_int10(result.value, row, col);
    } else if (result.kind == EVAL_CLOSURE) {
        console_puts("<lambda>", row, col);
    } else {
        console_puts(result.kind == EVAL_ERROR ? "error: " : "", row, col);
        console_puts(result.text, row, col);
    }
    repl_newline(row, col);
}

static void init_screen(void) {
    (void)VGA_STATUS;
    (void)LCD_STATUS;
    vga_clear();
    lcd_clear();
    draw_netx_logo();
    draw_shell_frame();
    draw_lcd_header();
}

static void init_interpreter(void) {
    GLOBAL_COUNT = 0u;
}

int main(void) {
    char line[LINE_MAX + 1u];
    char history[LINE_MAX + 1u];
    char draft[LINE_MAX + 1u];
    unsigned int line_len = 0u;
    unsigned int cursor_index = 0u;
    unsigned int cursor_row = REPL_TOP;
    unsigned int cursor_col = PROMPT_COL;
    unsigned int input_start_row = REPL_TOP;
    unsigned int typed_count = 0u;
    unsigned int shift_down = 0u;
    unsigned int caps_lock = 0u;
    unsigned int break_code = 0u;
    unsigned int extended_code = 0u;
    unsigned int last_scan = 0u;
    unsigned int last_char = 0u;
    unsigned int history_len = 0u;
    unsigned int history_active = 0u;
    unsigned int draft_len = 0u;
    unsigned int blink_counter = 0u;
    unsigned int cursor_visible = 1u;

    init_interpreter();
    init_screen();
    print_prompt(&cursor_row, &cursor_col);
    line[0] = '\0';
    history[0] = '\0';
    draft[0] = '\0';
    redraw_input_line(input_start_row, line, line_len, cursor_index, cursor_visible);
    lcd_update_status(last_scan, typed_count, last_char, shift_down, break_code, extended_code);

    while (1) {
        unsigned int status = KBD_STATUS;
        if ((status & 1u) == 0u) {
            blink_counter += 1u;
            if (blink_counter >= 500000u) {
                blink_counter = 0u;
                cursor_visible ^= 1u;
                redraw_input_line(input_start_row, line, line_len, cursor_index, cursor_visible);
            }
            continue;
        }

        blink_counter = 0u;
        cursor_visible = 1u;

        last_scan = KBD_DATA & 0xffu;
        if (last_scan == 0xF0u) {
            break_code = 1u;
            lcd_update_status(last_scan, typed_count, last_char, shift_down, break_code, extended_code);
            continue;
        }

        if (last_scan == 0xE0u) {
            extended_code = 1u;
            lcd_update_status(last_scan, typed_count, last_char, shift_down, break_code, extended_code);
            continue;
        }

        if (last_scan == 0x12u || last_scan == 0x59u) {
            shift_down = break_code ? 0u : 1u;
            break_code = 0u;
            extended_code = 0u;
            lcd_update_status(last_scan, typed_count, last_char, shift_down, break_code, extended_code);
            continue;
        }

        if (last_scan == 0x58u && !break_code && !extended_code) {
            caps_lock ^= 1u;
            lcd_update_status(last_scan, typed_count, last_char, shift_down, break_code, extended_code);
            continue;
        }

        if (extended_code) {
            if (!break_code) {
                if (last_scan == 0x6Bu) {
                    if (cursor_index > 0u) {
                        cursor_index -= 1u;
                    }
                } else if (last_scan == 0x74u) {
                    if (cursor_index < line_len) {
                        cursor_index += 1u;
                    }
                } else if (last_scan == 0x75u) {
                    if (history_len > 0u) {
                        if (!history_active) {
                            copy_line(draft, line, LINE_MAX);
                            draft_len = line_len;
                            history_active = 1u;
                        }
                        copy_line(line, history, LINE_MAX);
                        line_len = history_len;
                        cursor_index = line_len;
                    }
                } else if (last_scan == 0x72u) {
                    if (history_active) {
                        copy_line(line, draft, LINE_MAX);
                        line_len = draft_len;
                        cursor_index = line_len;
                        history_active = 0u;
                    }
                }
            }

            break_code = 0u;
            extended_code = 0u;
            redraw_input_line(input_start_row, line, line_len, cursor_index, cursor_visible);
            lcd_update_status(last_scan, typed_count, last_char, shift_down, break_code, extended_code);
            continue;
        }

        if (!break_code && !extended_code) {
            unsigned int ch = decode_set2(last_scan, shift_down, caps_lock);
            last_char = ch;
            if (ch == 0x08u) {
                if (cursor_index > 0u && line_len > 0u) {
                    for (unsigned int i = cursor_index - 1u; i < line_len; ++i) {
                        line[i] = line[i + 1u];
                    }
                    line_len -= 1u;
                    cursor_index -= 1u;
                }
            } else if (ch == 0x0Au || ch == 0x0Du) {
                if (unmatched_paren_count(line, line_len) > 0u && line_len < LINE_MAX) {
                    for (unsigned int i = line_len; i > cursor_index; --i) {
                        line[i] = line[i - 1u];
                    }
                    line[cursor_index] = '\n';
                    line_len += 1u;
                    cursor_index += 1u;
                    line[line_len] = '\0';
                } else {
                    line[line_len] = '\0';
                    if (line_len > 0u) {
                        copy_line(history, line, LINE_MAX);
                        history_len = line_len;
                    }
                    history_active = 0u;
                    draft[0] = '\0';
                    draft_len = 0u;
                    input_cursor_position(input_start_row, line, line_len, line_len, &cursor_row, &cursor_col);
                    redraw_input_line(input_start_row, line, line_len, cursor_index, 0u);
                    run_line(line, &cursor_row, &cursor_col);
                    line_len = 0u;
                    cursor_index = 0u;
                    line[0] = '\0';
                    print_prompt(&cursor_row, &cursor_col);
                    input_start_row = cursor_row;
                    redraw_input_line(input_start_row, line, line_len, cursor_index, cursor_visible);
                }
            } else if (ch == 0x09u) {
                unsigned int tab_spaces = 4u;
                if (line_len + tab_spaces > LINE_MAX) {
                    tab_spaces = LINE_MAX - line_len;
                }
                for (unsigned int n = 0u; n < tab_spaces; ++n) {
                    for (unsigned int i = line_len; i > cursor_index; --i) {
                        line[i] = line[i - 1u];
                    }
                    line[cursor_index] = ' ';
                    line_len += 1u;
                    cursor_index += 1u;
                }
                line[line_len] = '\0';
                history_active = 0u;
                typed_count += tab_spaces;
            } else if (ch != 0u && ch >= 0x20u && line_len < LINE_MAX) {
                for (unsigned int i = line_len; i > cursor_index; --i) {
                    line[i] = line[i - 1u];
                }
                line[cursor_index] = (char)ch;
                line_len += 1u;
                cursor_index += 1u;
                line[line_len] = '\0';
                history_active = 0u;
                typed_count += 1u;
            }
            redraw_input_line(input_start_row, line, line_len, cursor_index, cursor_visible);
        }

        break_code = 0u;
        extended_code = 0u;
        lcd_update_status(last_scan, typed_count, last_char, shift_down, break_code, extended_code);
    }

    return 0;
}
