# Global hotkeys via Carbon RegisterEventHotKey

PRD §10.6 originally listed Accessibility as a required permission for global hotkey listening. `HotkeyManager` instead registers hotkeys through the legacy Carbon HIToolbox API (`RegisterEventHotKey`), which macOS grants without any Accessibility prompt. This keeps onboarding down to a single permission (Screen Recording) at the cost of depending on an older API Apple could deprecate further; the alternative — a `CGEventTap` — would require Accessibility and complicate the permission story for a menu-bar-only utility.
