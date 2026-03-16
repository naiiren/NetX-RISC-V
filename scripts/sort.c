int main(void)
{
    int i, j, tmp;
    int arr[30];

    for (i = 0; i < 30; i++) {
        arr[i] = 30 - i;
    }

    for (i = 0; i < 30; i++) {
        for (j = 0; j < 30 - 1 - i; j++) {
            if (arr[j] > arr[j + 1]) {
                tmp        = arr[j];
                arr[j]     = arr[j + 1];
                arr[j + 1] = tmp;
            }
        }
    }

    for (i = 0; i < 29; i++) {
        if (arr[i] > arr[i + 1])
            return 0;
    }

    return 0x00c0ffee;
}
