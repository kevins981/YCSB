#include <cmath>
#include <iostream>
 

int main() { 
  double sum = 0;
  long ITEM_COUNT = 10000000000L;
  //long ITEM_COUNT = 1000L;
  double theta = 0.7;

  #pragma omp parallel for reduction(+ : sum) num_threads(64)
  for (long i = 0; i < ITEM_COUNT+1; i++) {
        sum += 1 / (pow(i+1, theta));
  }
  std::cout << "zeta is " << sum << std::endl;

}

