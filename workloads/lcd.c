#define LCD_STATUS (*(volatile unsigned int *)0x80000000u)
#define LCD_CTRL   (*(volatile unsigned int *)0x80000004u)
#define LCD_TEXT   ((volatile unsigned char *)0x80000020u)

static void lcd_clear(void) {
    LCD_CTRL = 1u;
    for (unsigned int i = 0; i < 32; ++i) {
        LCD_TEXT[i] = ' ';
    }
}

static void lcd_putc(unsigned int row, unsigned int col, unsigned char ch) {
    unsigned int idx = row * 16u + col;
    if (idx < 32u) {
        LCD_TEXT[idx] = ch;
    }
}

int main(void) {
    lcd_clear();
    lcd_putc(0, 0, 'N');
    lcd_putc(0, 1, 'e');
    lcd_putc(0, 2, 't');
    lcd_putc(0, 3, 'X');
    lcd_putc(0, 4, ' ');
    lcd_putc(0, 5, 'R');
    lcd_putc(0, 6, 'V');
    lcd_putc(0, 7, '3');
    lcd_putc(0, 8, '2');
    lcd_putc(0, 9, 'I');
    lcd_putc(0, 10, ' ');
    lcd_putc(0, 11, 'L');
    lcd_putc(0, 12, 'C');
    lcd_putc(0, 13, 'D');

    lcd_putc(1, 0, 'H');
    lcd_putc(1, 1, 'e');
    lcd_putc(1, 2, 'l');
    lcd_putc(1, 3, 'l');
    lcd_putc(1, 4, 'o');
    lcd_putc(1, 5, ',');
    lcd_putc(1, 6, ' ');
    lcd_putc(1, 7, 'D');
    lcd_putc(1, 8, 'E');
    lcd_putc(1, 9, '2');
    lcd_putc(1, 10, '-');
    lcd_putc(1, 11, '1');
    lcd_putc(1, 12, '1');
    lcd_putc(1, 13, '5');

    while (1) {
        (void)LCD_STATUS;
    }

    return 0;
}
