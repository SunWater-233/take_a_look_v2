from __future__ import annotations

import unittest

from take_a_look_backend.services.debug_info import DebugInfoIndex, SourceLocation


class DebugInfoIndexTests(unittest.TestCase):
    def setUp(self) -> None:
        self.index = DebugInfoIndex(
            [
                SourceLocation("C:/firmware/src/main.c", 10, 0x08000100),
                SourceLocation("C:/firmware/src/main.c", 12, 0x08000108),
                SourceLocation("C:/firmware/src/main.c", 12, 0x0800010C),
                SourceLocation("C:/firmware/src/motor.c", 5, 0x08000200),
            ]
        )

    def test_breakpoint_only_resolves_exact_executable_line(self) -> None:
        unavailable = self.index.resolve_breakpoint("c:\\firmware\\src\\main.c", 11)
        location = self.index.resolve_breakpoint("c:\\firmware\\src\\main.c", 12)

        self.assertIsNone(unavailable)
        self.assertIsNotNone(location)
        self.assertEqual(location.line, 12)  # type: ignore[union-attr]
        self.assertEqual(location.address, 0x08000108)  # type: ignore[union-attr]

    def test_executable_lines_are_grouped_by_source_file(self) -> None:
        self.assertEqual(
            self.index.executable_lines,
            {
                "C:/firmware/src/main.c": [10, 12],
                "C:/firmware/src/motor.c": [5],
            },
        )

    def test_unique_basename_and_program_counter_are_resolved(self) -> None:
        breakpoint = self.index.resolve_breakpoint("D:/checkout/motor.c", 5)
        current = self.index.resolve_address(0x0800010E)

        self.assertEqual(breakpoint.path, "C:/firmware/src/motor.c")  # type: ignore[union-attr]
        self.assertEqual(
            self.index.canonical_source_path("D:/checkout/motor.c"),
            "C:/firmware/src/motor.c",
        )
        self.assertEqual(current.line, 12)  # type: ignore[union-attr]


if __name__ == "__main__":
    unittest.main()
