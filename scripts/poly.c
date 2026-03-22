int mult(int x, int y) {
    int result = 0;
    while (y > 0) {
        if (y & 1) {
            result += x;
        }
        x <<= 1;
        y >>= 1;
    }
    return result;
}

int main(void)
{
    int poly[9];
    for (int i = 0; i < 9; i++) {
        poly[i] = i + 1;
    }

    int x = 10;
    int result = 0;
    for (int i = 0; i < 9; i++) {
        int term = poly[i];
        for (int j = 0; j < i; j++) {
            term = mult(term, x);
        }
        result += term;
    }

    if (result == 987654321) {
        return 0x00c0ffee;
    }

    return 0xdeadbeef;
}
