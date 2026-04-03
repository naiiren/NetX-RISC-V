int modulo(int a, int b) {
    while (a >= b) {
        a -= b;
    }
    return a;
}

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

int is_prime(int n) {
    if (n <= 1) return 0;
    for (int i = 2; mult(i, i) <= n; i++) {
        if (modulo(n, i) == 0) {
            return 0;
        }
    }
    return 1;
}

int main() {
    int prime[20], index = 0;
    for (int i = 2; i <= 40; i++) {
        if (is_prime(i)) {
            prime[index++] = i;
        }
    }

    if (prime[0]  == 2  && 
        prime[1]  == 3  && 
        prime[2]  == 5  && 
        prime[3]  == 7  && 
        prime[4]  == 11 &&
        prime[5]  == 13 && 
        prime[6]  == 17 && 
        prime[7]  == 19 &&
        prime[8]  == 23 && 
        prime[9]  == 29 &&
        prime[10] == 31 &&
        prime[11] == 37) {
        return 0x00C0FFEE;
    } else {
        return 0xDEADBEEF;
    }
}