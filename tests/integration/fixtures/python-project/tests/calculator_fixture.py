"""Tests for calculator.py functions."""

from src.calculator import add, subtract, multiply, divide, power, sqrt


def test_add_integers():
    assert add(2, 3) == 5


def test_add_floats():
    assert abs(add(1.1, 2.2) - 3.3) < 1e-9


def test_subtract():
    assert subtract(10, 4) == 6


def test_multiply():
    assert multiply(3, 7) == 21


def test_divide_normal():
    assert divide(10, 2) == 5.0


def test_divide_by_zero():
    assert divide(5, 0) == 0.0


def test_power():
    assert power(2, 8) == 256


def test_sqrt_positive():
    assert abs(sqrt(9) - 3.0) < 1e-9


def test_sqrt_negative_clamped():
    assert sqrt(-4) == 0.0
