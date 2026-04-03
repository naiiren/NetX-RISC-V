int modulo(int a, int b) {
    while (a >= b) {
        a -= b;
    }
    return a;
}

int gcd(int a, int b) {
    if (b == 0) return a;
    return gcd(b, modulo(a, b));
}

int min(int a, int b) {
    return a < b ? a : b;
}

int main() {
    for (int a = 2; a <= 10; ++a) {
        for (int b = 2; b <= 10; ++b) {
            int result = gcd(a, b);
            if (modulo(a, result) != 0 || modulo(b, result) != 0) {
                return 0xDEADBEEF;
            }
            for (int i = result + 1; i <= min(a, b); ++i) {
                if (modulo(a, i) == 0 && modulo(b, i) == 0) {
                    return 0xDEADBEEF;
                }
            }
        }
    }
    return 0x00C0FFEE;
}