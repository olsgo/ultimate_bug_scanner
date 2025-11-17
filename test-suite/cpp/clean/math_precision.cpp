#include <boost/multiprecision/cpp_dec_float.hpp>
#include <iostream>

int main() {
    boost::multiprecision::cpp_dec_float_50 money = 10;
    boost::multiprecision::cpp_dec_float_50 price = 3;
    auto change = money - price * 3;
    std::cout << change << std::endl;
    return 0;
}
