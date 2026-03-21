int fib(int n) {
    if (n == 0 || n == 1) {
        return 1;
    }
    return fib(n - 1) + fib(n - 2);
}

int main() {
    int arr[10];
    for (int i = 0; i < 10; ++i) {
        arr[i] = fib(i);
    }

    for (int i = 2; i < 10; ++i) {
        if (arr[i] != arr[i - 1] + arr[i - 2]) {
            return 0xdeadbeed;
        }
    }
    return 0x00c0ffee;
}