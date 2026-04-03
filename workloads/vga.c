#define VGA_STATUS (*(volatile unsigned int *)0x80000100u)
#define VGA_TEXT   ((volatile unsigned char *)0x80001000u)
#define LCD_CTRL   (*(volatile unsigned int *)0x80000004u)
#define LCD_TEXT   ((volatile unsigned char *)0x80000020u)

#define VGA_COLS 80u
#define VGA_ROWS 28u
#define LCD_COLS 16u
#define LCD_ROWS 2u

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

static void vga_print_ascii(unsigned int row, unsigned int col) {
    unsigned char ch = 0x20u;
    for (unsigned int r = 0; r < 6 && row + r < VGA_ROWS; ++r) {
        for (unsigned int c = 0; c < 16 && col + c < VGA_COLS; ++c) {
            if (ch > 0x7eu) {
                return;
            }
            vga_putc(row + r, col + c, ch);
            ++ch;
        }
    }
}

static void vga_banner(void) {
    vga_putc(2,  6, 'N');
    vga_putc(2,  7, 'E');
    vga_putc(2,  8, 'T');
    vga_putc(2,  9, 'X');
    vga_putc(2, 11, 'V');
    vga_putc(2, 12, 'G');
    vga_putc(2, 13, 'A');
    vga_putc(2, 15, 'D');
    vga_putc(2, 16, 'E');
    vga_putc(2, 17, 'M');
    vga_putc(2, 18, 'O');

    vga_putc(5, 6, '1');
    vga_putc(5, 7, '6');
    vga_putc(5, 8, ':');
    vga_putc(5, 9, '9');
    vga_putc(5,11, 'W');
    vga_putc(5,12, 'I');
    vga_putc(5,13, 'D');
    vga_putc(5,14, 'E');
    vga_putc(5,15, 'S');
    vga_putc(5,16, 'C');
    vga_putc(5,17, 'R');
    vga_putc(5,18, 'E');
    vga_putc(5,19, 'E');
    vga_putc(5,20, 'N');

    vga_putc(8, 6, 'L');
    vga_putc(8, 7, 'C');
    vga_putc(8, 8, 'D');
    vga_putc(8,10, '-');
    vga_putc(8,12, 'P');
    vga_putc(8,13, 'S');
    vga_putc(8,14, '2');
    vga_putc(8,16, '-');
    vga_putc(8,18, 'V');
    vga_putc(8,19, 'G');
    vga_putc(8,20, 'A');

    vga_putc(11, 6, 'R');
    vga_putc(11, 7, 'U');
    vga_putc(11, 8, 'N');
    vga_putc(11,10, 'O');
    vga_putc(11,11, 'N');
    vga_putc(11,13, 'D');
    vga_putc(11,14, 'E');
    vga_putc(11,15, '2');
    vga_putc(11,16, '-');
    vga_putc(11,17, '1');
    vga_putc(11,18, '1');
    vga_putc(11,19, '5');
    vga_putc(11,20, '!');

    vga_putc(14, 6, 'A');
    vga_putc(14, 7, 'S');
    vga_putc(14, 8, 'C');
    vga_putc(14, 9, 'I');
    vga_putc(14,10, 'I');
    vga_putc(14,12, '0');
    vga_putc(14,13, 'X');
    vga_putc(14,14, '2');
    vga_putc(14,15, '0');
    vga_putc(14,17, '-');
    vga_putc(14,19, '0');
    vga_putc(14,20, 'X');
    vga_putc(14,21, '7');
    vga_putc(14,22, 'E');

    vga_print_ascii(17, 6);
}

static void lcd_banner(void) {
    lcd_putc(0, 0, 'V');
    lcd_putc(0, 1, 'G');
    lcd_putc(0, 2, 'A');
    lcd_putc(0, 4, 'D');
    lcd_putc(0, 5, 'E');
    lcd_putc(0, 6, 'M');
    lcd_putc(0, 7, 'O');

    lcd_putc(1, 0, 'N');
    lcd_putc(1, 1, 'E');
    lcd_putc(1, 2, 'T');
    lcd_putc(1, 3, 'X');
    lcd_putc(1, 5, 'R');
    lcd_putc(1, 6, 'V');
    lcd_putc(1, 7, '3');
    lcd_putc(1, 8, '2');
    lcd_putc(1, 9, 'I');
}

int main(void) {
    lcd_clear();
    lcd_banner();
    vga_clear();
    vga_banner();

    while (1) {
        (void)VGA_STATUS;
    }

    return 0;
}
