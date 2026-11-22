#!/usr/bin/env python3
"""Create an isolated Tizen or webOS dependency profile in a work copy.

The main pubspec remains cross-platform. TV builds use a temporary source tree
and remove media_kit/libmpv, whose native implementations do not target these
TV operating systems.
"""

from pathlib import Path
import sys

WEBOS_PLUGIN_REF = "3a742bb86b04e261044f0864f9b1f71acf0bbad3"


def replace_once(text: str, old: str, new: str) -> str:
    if text.count(old) != 1:
        raise RuntimeError(f"Expected exactly one pubspec entry: {old!r}")
    return text.replace(old, new, 1)


def plugin(path: str) -> str:
    return (
        "    git:\n"
        "      url: https://github.com/lg-flutter-webos/plugins.git\n"
        f"      ref: {WEBOS_PLUGIN_REF}\n"
        f"      path: {path}\n"
    )


def main() -> None:
    if len(sys.argv) != 3 or sys.argv[2] not in {"tizen", "webos"}:
        raise SystemExit("usage: configure_tv_pubspec.py <workdir> <tizen|webos>")
    platform = sys.argv[2]
    pubspec = Path(sys.argv[1]).resolve() / "pubspec.yaml"
    text = pubspec.read_text()

    # libmpv/media_kit is intentionally absent from both TV profiles.
    for dependency in (
        "  media_kit: ^1.2.6\n",
        "  media_kit_video: ^2.0.1\n",
        "  media_kit_libs_video: ^1.0.7\n",
        "    path: vendor/media_kit_libs_macos_video\n",
        "    path: vendor/media_kit_libs_android_video\n",
    ):
        text = replace_once(text, dependency, "")
    text = text.replace(
        "  media_kit_libs_macos_video:\n",
        "",
    ).replace(
        "  media_kit_libs_android_video:\n",
        "",
    )
    text = replace_once(text, "dependency_overrides:\n", "")

    if platform == "tizen":
        text = replace_once(text, "  video_player: ^2.11.1\n", "  video_player: ^2.14.0\n")
        text = replace_once(text, "  package_info_plus: ^9.0.0\n", "  package_info_plus: ^10.2.2\n")
        additions = (
            "  video_player_tizen: ^2.6.0\n"
            "  flutter_secure_storage_tizen: ^0.1.6\n"
            "  path_provider_tizen: ^2.3.3\n"
            "  package_info_plus_tizen: ^1.2.0\n"
            "  url_launcher_tizen: ^2.1.9\n"
        )
    else:
        text = replace_once(text, "  sdk: ^3.12.2\n", "  sdk: '>=3.10.0 <4.0.0'\n")
        text = replace_once(text, "  flutter_secure_storage: ^10.3.1\n", "  flutter_secure_storage: 9.2.4\n")
        text = replace_once(text, "  package_info_plus: ^9.0.0\n", "  package_info_plus: 4.2.0\n")
        additions = (
            "  video_player_webos:\n" + plugin("packages/video_player") +
            "  flutter_secure_storage_webos:\n" + plugin("packages/flutter_secure_storage") +
            "  path_provider_webos:\n" + plugin("packages/path_provider") +
            "  package_info_plus_webos:\n" + plugin("packages/package_info_plus") +
            "  url_launcher_webos:\n" + plugin("packages/url_launcher")
        )

    text = replace_once(text, "  file_selector: ^1.1.0\n", additions + "  file_selector: ^1.1.0\n")
    pubspec.write_text(text)
    lock = pubspec.with_name("pubspec.lock")
    if lock.exists():
        lock.unlink()

    # Analyzer and compilers must not see native-only media_kit sources in the
    # isolated TV tree. They are unreachable from tv_main.dart, but leaving
    # them in place would make `analyze lib` require the removed dependency.
    for relative in (
        "lib/main.dart",
        "lib/player/player_screen.dart",
        "lib/player/advanced_playback_controller.dart",
        "lib/player/gyuni_player_controls.dart",
        "lib/player/subtitle_controls_overlay.dart",
    ):
        native_source = pubspec.parent / relative
        if native_source.exists():
            native_source.unlink()

    print(f"Configured {platform} dependency profile: {pubspec}")


if __name__ == "__main__":
    main()
