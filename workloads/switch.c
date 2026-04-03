int switch_func(int select) {
    switch (select) {
        case 0x00: return 0;
        case 0x01: return 1;
        case 0xa5: return 2;
        case 0xff: return 3;
        case 0x7f: return 4;
        case 0x80: return 5;
        case 0x55: return 6;
        case 0xaa: return 7;
        case 0x33: return 8;
        case 0xcc: return 9;
        case 0x0f: return 10;
        default:
            return -1;
    }
}

int main(void) {
    if (switch_func(0x00) != 0)  return 0xDEADBEEF;
    if (switch_func(0x01) != 1)  return 0xDEADBEEF;
    if (switch_func(0xa5) != 2)  return 0xDEADBEEF;
    if (switch_func(0xff) != 3)  return 0xDEADBEEF;
    if (switch_func(0x7f) != 4)  return 0xDEADBEEF;
    if (switch_func(0x80) != 5)  return 0xDEADBEEF;
    if (switch_func(0x55) != 6)  return 0xDEADBEEF;
    if (switch_func(0xaa) != 7)  return 0xDEADBEEF;
    if (switch_func(0x33) != 8)  return 0xDEADBEEF;
    if (switch_func(0xcc) != 9)  return 0xDEADBEEF;
    if (switch_func(0x0f) != 10) return 0xDEADBEEF;
    if (switch_func(0x10) != -1) return 0xDEADBEEF;
    return 0x00C0FFEE;
}