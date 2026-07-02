// Command example is a minimal Go module exercised by the flake-checks
// helpers in CI.
package main

//go:generate go run gen.go

import "fmt"

func add(a, b int) int {
	return a + b
}

func main() {
	fmt.Println(greeting)
	fmt.Println(add(1, 2))
}
