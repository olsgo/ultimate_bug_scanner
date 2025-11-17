#include <climits>
#include <cstdint>
#include <iostream>

int main() {
    int sum = INT_MAX;
    int value = 42;
    sum += value; // overflow

    double money = 10.0;
    double price = 3.0;
    double change = money - price * 3; // floating precision
    if (change == 0.0) {
        std::cout << "exact" << std::endl;
    }

    std::cout << sum << change << std::endl;
    return 0;
}
