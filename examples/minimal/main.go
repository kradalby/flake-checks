// Command example is a minimal Go module exercised by the flake-checks
// helpers in CI.
package main

import "fmt"

func add(a, b int) int {
	return a + b
}

func main() {
	fmt.Println(add(1, 2))
}
