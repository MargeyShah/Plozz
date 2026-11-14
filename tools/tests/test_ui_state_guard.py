"""Regression tests for the UI loading-state guard.

The guard exists because both anti-patterns shipped and both were reported by a
viewer: a skeleton armed by a delay (Home 250ms -> 2s -> 6s, detail rail 250ms)
and a skeleton suppressed without reserving its geometry (detail episode rail).
"""
import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("ui_state_guard", ROOT / "tools" / "ui-state-guard.py")
guard = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(guard)


class UILoadingStateGuardTests(unittest.TestCase):
    def write(self, name: str, body: str) -> pathlib.Path:
        directory = pathlib.Path(self.enterContext(__import__("tempfile").TemporaryDirectory()))
        path = directory / name
        path.write_text(body)
        return path

    def test_flags_skeleton_armed_after_sleep(self) -> None:
        path = self.write("Home.swift", """
        struct Home: View {
            @State private var skeletonArmed = false
            var body: some View {
                Color.clear.task {
                    try? await Task.sleep(for: .milliseconds(250))
                    skeletonArmed = true
                }
            }
        }
        """)
        self.assertTrue(guard.check_time_gated_loading(path))

    def test_allows_background_sleep_without_loading_flag(self) -> None:
        path = self.write("Refresh.swift", """
        struct Refresh {
            func run() async {
                try? await Task.sleep(for: .seconds(20))
                await refresh()
            }
        }
        """)
        self.assertEqual(guard.check_time_gated_loading(path), [])

    def test_flags_conditionally_shown_skeleton(self) -> None:
        path = self.write("Rail.swift", """
        struct Rail: View {
            var body: some View {
                if isLoading {
                    EpisodeSkeletonRail()
                } else {
                    RailContent()
                }
            }
        }
        """)
        self.assertTrue(guard.check_reserved_geometry(path))

    def test_allows_reserved_placeholder(self) -> None:
        path = self.write("Rail.swift", """
        struct Rail: View {
            var body: some View {
                PlozzReservedPlaceholder(isPending: isLoading, revealsPlaceholder: false) {
                    EpisodeSkeletonRail()
                } content: {
                    RailContent()
                }
            }
        }
        """)
        self.assertEqual(guard.check_reserved_geometry(path), [])


if __name__ == "__main__":
    unittest.main()
