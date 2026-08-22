from __future__ import annotations

import ctypes
import os
import queue
import sys
import tkinter as tk
import tkinter.font as tkfont
import webbrowser
from dataclasses import dataclass
from concurrent.futures import Future, ThreadPoolExecutor
from pathlib import Path
from tkinter import messagebox, simpledialog, ttk
from typing import Any, Callable
from uuid import UUID

from PIL import Image, ImageTk
import pystray

from .account_manager import CodexAccountManager, CodexAccountManagerError, ManagedLoginProcess
from .app_settings import (
    APP_VERSION,
    AUTO_REFRESH_OPTIONS,
    AppSettingsError,
    AppSettingsStore,
    is_startup_enabled,
    set_startup_enabled,
)
from .brand_icon import build_codex_vitals_icon, build_ramter_studio_logo
from .codex_api import AuthBackedIdentity
from .codex_api import fetch_snapshot
from .codex_desktop import CodexDesktopControlError, restart_codex_desktop
from .compact_ui import AccountRow, AccountRowActions, HoverTooltip, IconButton, ToggleSwitch, draw_rounded_rectangle
from .models import AccountRuntimeState, AccountUsageSnapshot, RemovedAccountIdentity, StoredAccount, StoredAccountSource, utc_now
from .presentation_logic import account_sort_key, is_active_account
from .stores import AccountStore, SnapshotStore
from .update_manager import UpdateManager, UpdateManagerError


APP_DISPLAY_NAME = "Codex Vitals"
APP_INTERNAL_NAME = "CodexVitals"
HOMEPAGE_URL = "https://ramterstudio.com/codex-vitals/"
GITHUB_URL = "https://github.com/Joowonoil/Codex-Vitals"
FEEDBACK_URL = "mailto:ramterstudio@gmail.com?subject=Codex%20Vitals%20Feedback"
RAMTER_STUDIO_URL = "https://ramterstudio.com"


@dataclass(slots=True)
class RoundedButtonTheme:
    bg: str
    fg: str
    hover: str
    border: str
    disabled_bg: str
    disabled_fg: str


@dataclass(slots=True)
class PresentationState:
    search_query: str
    filtered_accounts: list[StoredAccount]
    account_count: int
    low_quota_count: int
    usable_quota_count: int
    exhausted_count: int

    @property
    def menu_bar_quota_state(self) -> str:
        if self.account_count == 0:
            return "empty"
        if self.usable_quota_count > 0:
            return "available"
        if self.exhausted_count == self.account_count:
            return "unavailable"
        return "unresolved"


class RoundedButton(tk.Canvas):
    def __init__(
        self,
        parent: tk.Widget,
        text: str,
        command: Callable[[], None],
        theme: RoundedButtonTheme,
        font: tuple[str, int] | tuple[str, int, str],
        icon: str | None,
        icon_font: tuple[str, int] | tuple[str, int, str] | None,
        radius: int,
        pad_x: int,
        pad_y: int,
    ) -> None:
        super().__init__(
            parent,
            highlightthickness=0,
            bd=0,
            relief="flat",
            bg=parent.cget("bg"),
            cursor="hand2",
            takefocus=0,
        )
        self.text = text
        self.command = command
        self.theme = theme
        self.font = font
        self.icon = icon
        self.icon_font = icon_font
        self.radius = radius
        self.pad_x = pad_x
        self.pad_y = pad_y
        self.enabled = True
        self._hovering = False
        self._text_font = tkfont.Font(font=self.font)
        self._icon_resolved_font = tkfont.Font(font=self.icon_font) if self.icon_font else None

        self.bind("<Configure>", self._redraw)
        self.bind("<Enter>", self._on_enter)
        self.bind("<Leave>", self._on_leave)
        self.bind("<Button-1>", self._on_click)

        width, height = self._measure()
        self.configure(width=width, height=height)
        self._redraw()

    def set_enabled(self, enabled: bool) -> None:
        self.enabled = enabled
        self.configure(cursor="hand2" if enabled else "arrow")
        self._redraw()

    def set_text(self, text: str) -> None:
        self.text = text
        width, height = self._measure()
        self.configure(width=width, height=height)
        self._redraw()

    def set_theme(self, theme: RoundedButtonTheme) -> None:
        self.theme = theme
        self._redraw()

    def set_icon(self, icon: str | None) -> None:
        self.icon = icon
        width, height = self._measure()
        self.configure(width=width, height=height)
        self._redraw()

    def _on_enter(self, _: tk.Event[Any]) -> None:
        self._hovering = True
        self._redraw()

    def _on_leave(self, _: tk.Event[Any]) -> None:
        self._hovering = False
        self._redraw()

    def _on_click(self, _: tk.Event[Any]) -> None:
        if self.enabled:
            self.command()

    def _redraw(self, _: tk.Event[Any] | None = None) -> None:
        self.delete("all")
        width = max(1, self.winfo_width())
        height = max(1, self.winfo_height())

        if self.enabled:
            fill = self.theme.hover if self._hovering else self.theme.bg
            fg = self.theme.fg
            border = self.theme.border
        else:
            fill = self.theme.disabled_bg
            fg = self.theme.disabled_fg
            border = self.theme.border

        self._rounded_rect(0, 0, width - 1, height - 1, self.radius, fill, border)
        text_width = self._text_font.measure(self.text)
        icon_width = 0
        if self.icon and self._icon_resolved_font:
            icon_width = self._icon_resolved_font.measure(self.icon) + 8

        total_width = text_width + icon_width
        start_x = (width - total_width) / 2

        if self.icon and self._icon_resolved_font:
            icon_text_width = self._icon_resolved_font.measure(self.icon)
            self.create_text(
                start_x + (icon_text_width / 2),
                height // 2,
                text=self.icon,
                fill=fg,
                font=self._icon_resolved_font,
            )
            start_x += icon_text_width + 8

        self.create_text(
            start_x + (text_width / 2),
            height // 2,
            text=self.text,
            fill=fg,
            font=self._text_font,
        )

    def _measure(self) -> tuple[int, int]:
        text_width = self._text_font.measure(self.text)
        text_height = self._text_font.metrics("linespace")
        icon_width = 0
        icon_height = 0
        if self.icon and self._icon_resolved_font:
            icon_width = self._icon_resolved_font.measure(self.icon) + 8
            icon_height = self._icon_resolved_font.metrics("linespace")

        width = text_width + icon_width + (self.pad_x * 2)
        height = max(text_height, icon_height) + (self.pad_y * 2)
        return width, height

    def _rounded_rect(self, x1: int, y1: int, x2: int, y2: int, radius: int, fill: str, outline: str) -> None:
        points = [
            x1 + radius, y1,
            x2 - radius, y1,
            x2, y1,
            x2, y1 + radius,
            x2, y2 - radius,
            x2, y2,
            x2 - radius, y2,
            x1 + radius, y2,
            x1, y2,
            x1, y2 - radius,
            x1, y1 + radius,
            x1, y1,
        ]
        self.create_polygon(points, smooth=True, fill=fill, outline=outline)


class StudioLogoLink(tk.Canvas):
    def __init__(
        self,
        parent: tk.Widget,
        *,
        logo: ImageTk.PhotoImage,
        command: Callable[[], None],
        palette: dict[str, str],
        caption_font: tuple[str, int] | tuple[str, int, str],
        icon_font: tuple[str, int] | tuple[str, int, str],
        external_icon: str,
        height: int = 59,
    ) -> None:
        super().__init__(
            parent,
            height=height,
            bg=palette["panel"],
            highlightthickness=0,
            bd=0,
            cursor="hand2",
            takefocus=0,
        )
        self.logo = logo
        self.command = command
        self.palette = palette
        self.caption_font = caption_font
        self.icon_font = icon_font
        self.external_icon = external_icon
        self.link_height = height
        self._hovering = False

        self.bind("<Configure>", self._redraw)
        self.bind("<Enter>", self._on_enter)
        self.bind("<Leave>", self._on_leave)
        self.bind("<Button-1>", self._on_click)
        HoverTooltip(self, "Open RamterStudio website", palette)
        self._redraw()

    def _on_enter(self, _: tk.Event[Any]) -> None:
        self._hovering = True
        self._redraw()

    def _on_leave(self, _: tk.Event[Any]) -> None:
        self._hovering = False
        self._redraw()

    def _on_click(self, _: tk.Event[Any]) -> None:
        self.command()

    def _redraw(self, _: tk.Event[Any] | None = None) -> None:
        self.delete("all")
        width = max(1, self.winfo_width())
        height = max(1, self.winfo_height())
        if self._hovering:
            draw_rounded_rectangle(
                self,
                0,
                2,
                width - 1,
                height - 2,
                9,
                fill=self.palette["control_hover"],
                outline=self.palette["control_border"],
            )

        self.create_text(
            2,
            6,
            text="Made by",
            fill=self.palette["muted"],
            font=self.caption_font,
            anchor="nw",
        )
        self.create_image(2, 27, image=self.logo, anchor="nw")
        self.create_text(
            width - 6,
            height / 2,
            text=self.external_icon,
            fill=self.palette["muted"],
            font=self.icon_font,
            anchor="e",
        )


class DarkScrollbar(tk.Canvas):
    def __init__(
        self,
        parent: tk.Widget,
        command: Callable[..., Any],
        palette: dict[str, str],
        width: int = 11,
    ) -> None:
        super().__init__(
            parent,
            width=width,
            highlightthickness=0,
            bd=0,
            relief="flat",
            bg=palette["list"],
            cursor="hand2",
            takefocus=0,
        )
        self.command = command
        self.palette = palette
        self.bar_width = width
        self.first = 0.0
        self.last = 1.0
        self.thumb_top = 0
        self.thumb_bottom = 0
        self.drag_offset = 0
        self.dragging = False

        self.bind("<Configure>", self._redraw)
        self.bind("<Button-1>", self._on_press)
        self.bind("<B1-Motion>", self._on_drag)
        self.bind("<ButtonRelease-1>", self._on_release)

        self._redraw()

    def set(self, first: str | float, last: str | float) -> None:
        self.first = max(0.0, min(1.0, float(first)))
        self.last = max(self.first, min(1.0, float(last)))
        self._redraw()

    def _on_press(self, event: tk.Event[Any]) -> None:
        if self.thumb_top <= event.y <= self.thumb_bottom:
            self.dragging = True
            self.drag_offset = event.y - self.thumb_top
            return

        self._jump_to(event.y)

    def _on_drag(self, event: tk.Event[Any]) -> None:
        if not self.dragging:
            return

        height = max(1, self.winfo_height())
        thumb_size = max(24, self.thumb_bottom - self.thumb_top)
        track = max(1, height - thumb_size)
        top = min(max(0, event.y - self.drag_offset), track)
        first = top / track if track else 0.0
        self.command("moveto", str(first))

    def _on_release(self, _: tk.Event[Any]) -> None:
        self.dragging = False

    def _jump_to(self, y: int) -> None:
        height = max(1, self.winfo_height())
        visible = max(0.05, self.last - self.first)
        thumb_size = max(24, int(height * visible))
        track = max(1, height - thumb_size)
        target = min(max(0, y - (thumb_size // 2)), track)
        first = target / track if track else 0.0
        self.command("moveto", str(first))

    def _redraw(self, _: tk.Event[Any] | None = None) -> None:
        self.delete("all")
        width = max(1, self.winfo_width())
        height = max(1, self.winfo_height())

        visible = max(0.05, self.last - self.first)
        thumb_size = max(24, int(height * visible))
        track = max(1, height - thumb_size)
        top = int(track * self.first)
        bottom = top + thumb_size
        self.thumb_top = top
        self.thumb_bottom = bottom

        draw_rounded_rectangle(
            self,
            2,
            top + 2,
            width - 2,
            bottom - 2,
            3,
            fill=self.palette["disabled"],
        )


class CodexVitalsWindowsApp:
    GROUP_REFRESH_FLUSH_MS = 120
    QUEUE_POLL_MS = 150
    SEARCH_RENDER_MS = 80
    CARD_RENDER_BATCH_ROWS = 2
    ELLIPSIS_CACHE_MAX = 4096

    def __init__(self, start_hidden: bool = False) -> None:
        self.account_store = AccountStore()
        self.snapshot_store = SnapshotStore()
        self.account_manager = CodexAccountManager()
        self.settings_store = AppSettingsStore()
        self.app_settings = self.settings_store.load()
        worker_count = min(12, max(4, (os.cpu_count() or 4) * 2))
        self.executor = ThreadPoolExecutor(max_workers=worker_count, thread_name_prefix="codexvitals")
        self.events: queue.Queue[tuple[Any, ...]] = queue.Queue()
        self.update_manager = UpdateManager(
            on_shutdown_requested=lambda: self.events.put(("update_shutdown",)),
            on_status=lambda message: self.events.put(("update_status", message)),
        )

        self.accounts: list[StoredAccount] = []
        self.removed_accounts: list[RemovedAccountIdentity] = []
        self.runtime_states: dict[UUID, AccountRuntimeState] = {}
        self.nickname_drafts: dict[UUID, str] = {}
        self.selected_account_id: UUID | None = None
        self.active_identity: AuthBackedIdentity | None = None
        self.status_message: str | None = None
        self.is_refreshing_all = False
        self.is_adding_account = False
        self.reauthenticating_account_id: UUID | None = None
        self._group_refresh_pending = 0
        self._add_handle: ManagedLoginProcess | None = None
        self._reauth_handle: ManagedLoginProcess | None = None
        self._quitting = False
        self._group_refresh_flush_job: str | None = None
        self._group_refresh_flush_pending = False
        self._resize_job: str | None = None
        self._render_job: str | None = None
        self._cards_render_job: str | None = None
        self._search_render_job: str | None = None
        self._queue_poll_job: str | None = None
        self._auto_refresh_job: str | None = None
        self._initial_refresh_job: str | None = None
        self._restart_desktop_job: str | None = None
        self._cards_render_token = 0
        self._last_render_width = 0
        self._accounts_revision = 0
        self._runtime_revision = 0
        self._search_revision = 0
        self._presentation_cache_key: tuple[int, int, int] | None = None
        self._presentation_cache: PresentationState | None = None
        self._font_object_cache: dict[tuple[Any, ...], tkfont.Font] = {}
        self._ellipsize_cache: dict[tuple[str, tuple[Any, ...], int], str] = {}
        self.search_visible = False
        self.settings_visible = False
        self.settings_status_message = ""
        self.update_toggle: ToggleSwitch | None = None
        self.check_update_button: RoundedButton | None = None
        self.start_hidden = start_hidden

        self.is_dark_mode = self._system_prefers_dark()
        self.palette = self._build_palette(self.is_dark_mode)

        self.root = tk.Tk()
        self.root.title(APP_DISPLAY_NAME)
        screen_width = self.root.winfo_screenwidth()
        screen_height = self.root.winfo_screenheight()
        window_width = max(820, min(1020, screen_width - 40))
        window_height = max(360, min(520, screen_height - 80))
        window_x = max(0, (screen_width - window_width) // 2)
        window_y = max(0, (screen_height - window_height) // 2)
        self.root.geometry(f"{window_width}x{window_height}+{window_x}+{window_y}")
        self.root.minsize(min(900, window_width), 360)
        self.root.configure(bg=self.palette["bg"])
        self.root.protocol("WM_DELETE_WINDOW", self.hide_window)
        self.search_var = tk.StringVar(master=self.root)
        self.auto_refresh_var = tk.StringVar(
            master=self.root,
            value=self._refresh_interval_label(self.app_settings.auto_refresh_minutes),
        )
        self.root.bind("<Configure>", self._on_root_configure)
        self.root.bind("<Control-f>", lambda _: self._toggle_search())
        self.root.bind("<Control-r>", lambda _: self.refresh_all())
        self.root.bind("<Control-n>", lambda _: self.start_or_cancel_add_account())
        self.root.bind("<Control-comma>", lambda _: self._toggle_settings())
        self.root.bind("<Escape>", lambda _: self._handle_escape())

        self._configure_fonts()

        self.window_icon_images: list[ImageTk.PhotoImage] = []
        self.brand_icon_image: ImageTk.PhotoImage | None = None
        self.ramter_studio_logo_image: ImageTk.PhotoImage | None = None
        self._set_window_icon()

        self._configure_styles()
        self._build_ui()
        self.update_manager.initialize(self.app_settings.automatically_check_for_updates)
        self._sync_update_controls()
        self.root.update_idletasks()
        self._apply_dark_title_bar()
        self._setup_tray_icon()
        self._load_initial_state()
        self._render_now()
        if self.start_hidden:
            self.hide_window()

        self.search_var.trace_add("write", lambda *_: self._on_search_change())
        self._queue_poll_job = self.root.after(self.QUEUE_POLL_MS, self._process_event_queue)
        self._initial_refresh_job = self.root.after(800, self.refresh_all)
        self._schedule_auto_refresh()

    def run(self) -> None:
        self.root.mainloop()

    def quit(self) -> None:
        self._quitting = True
        for job_name in (
            "_search_render_job",
            "_cards_render_job",
            "_render_job",
            "_resize_job",
            "_group_refresh_flush_job",
            "_queue_poll_job",
            "_auto_refresh_job",
            "_initial_refresh_job",
            "_restart_desktop_job",
        ):
            job = getattr(self, job_name, None)
            if job is None:
                continue
            try:
                self.root.after_cancel(job)
            except tk.TclError:
                pass
            setattr(self, job_name, None)
        if self.tray_icon is not None:
            try:
                self.tray_icon.stop()
            except Exception:
                pass
        self.update_manager.cleanup()
        self.executor.shutdown(wait=False, cancel_futures=True)
        self.root.destroy()

    def show_window(self) -> None:
        self.root.deiconify()
        self.root.lift()
        self.root.focus_force()

    def hide_window(self) -> None:
        self.root.withdraw()

    def refresh_all(self) -> None:
        if self._initial_refresh_job is not None:
            try:
                self.root.after_cancel(self._initial_refresh_job)
            except tk.TclError:
                pass
            self._initial_refresh_job = None

        if not self.accounts or self.is_refreshing_all:
            return

        refreshable_accounts = [
            account for account in self.accounts
            if not self._requires_reauthentication(account.id)
        ]
        if not refreshable_accounts:
            return

        self.is_refreshing_all = True
        self._group_refresh_pending = len(refreshable_accounts)
        for account in refreshable_accounts:
            state = self.runtime_states.setdefault(account.id, AccountRuntimeState())
            state.is_loading = True
            self.runtime_states[account.id] = state
            self._submit_future(
                self.executor.submit(fetch_snapshot, account, False),
                "refresh_result",
                account.id,
                True,
            )
        self._render()

    def refresh_account(self, account: StoredAccount) -> None:
        state = self.runtime_states.setdefault(account.id, AccountRuntimeState())
        if state.is_loading:
            return

        state.is_loading = True
        self.runtime_states[account.id] = state
        self._submit_future(
            self.executor.submit(fetch_snapshot, account, True),
            "refresh_result",
            account.id,
            False,
        )
        self._render()

    def start_or_cancel_add_account(self) -> None:
        if self.is_adding_account:
            self.cancel_add_account()
        else:
            self.start_add_account()

    def start_add_account(self) -> None:
        if self.is_adding_account:
            return

        self.is_adding_account = True
        self.status_message = "Complete or cancel the Codex sign-in flow in your browser."
        self._add_handle = ManagedLoginProcess()
        self._submit_future(
            self.executor.submit(self.account_manager.add_managed_account, self._add_handle),
            "add_account_result",
        )
        self._render()

    def cancel_add_account(self) -> None:
        if not self.is_adding_account or self._add_handle is None:
            return

        self.status_message = "Cancelling account setup."
        self._add_handle.cancel()
        self._render()

    def reauthenticate(self, account: StoredAccount) -> None:
        if self.reauthenticating_account_id is not None:
            return

        self.reauthenticating_account_id = account.id
        self.status_message = f"Waiting for {account.display_name} to sign in again."
        self._reauth_handle = ManagedLoginProcess()
        self._submit_future(
            self.executor.submit(self.account_manager.reauthenticate, account, self._reauth_handle),
            "reauth_result",
            account.id,
        )
        self._render()

    def update_nickname(self, account_id: UUID) -> None:
        account = next((candidate for candidate in self.accounts if candidate.id == account_id), None)
        if account is None:
            return

        draft = self.nickname_drafts.get(account_id, "").strip()
        account.nickname = draft or None
        self.nickname_drafts[account_id] = draft
        account.updated_at = utc_now()
        self._mark_accounts_dirty()
        self._persist_accounts_silently()
        self._render()

    def remove_account(self, account: StoredAccount) -> None:
        confirmed = messagebox.askyesno(
            "Remove Account",
            f"{account.display_name} will be removed from {APP_DISPLAY_NAME}.",
            parent=self.root,
        )
        if not confirmed:
            return

        removed_identity = RemovedAccountIdentity.from_account(account)
        self.removed_accounts = [candidate for candidate in self.removed_accounts if not candidate.matches(account)]
        self.removed_accounts.append(removed_identity)

        self.accounts = [
            candidate
            for candidate in self.accounts
            if candidate.id != account.id and not removed_identity.matches(candidate)
        ]
        self.runtime_states.pop(account.id, None)
        self.nickname_drafts.pop(account.id, None)
        self._mark_accounts_dirty()
        self._mark_runtime_dirty()
        try:
            self.account_manager.remove_managed_files_if_owned(account)
            self.account_store.save_accounts(self.accounts, self.removed_accounts)
            self._ensure_selection()
            self.status_message = f"{account.display_name} removed."
        except CodexAccountManagerError as error:
            self.status_message = str(error)
        self._render()

    def switch_account(self, account: StoredAccount) -> None:
        if self._is_active_account(account):
            self.status_message = f"{account.display_name} is already the active Codex account."
            self._render()
            return

        try:
            result = self.account_manager.switch_active_account(account, self.accounts)
            if result.materialized_account is not None:
                self._replace_or_append_account(result.materialized_account)
            self._refresh_active_identity()
            self._load_initial_state()
            self.status_message = (
                f"Active account switched to {account.display_name}. "
                "Restarting Codex Desktop to apply the new session."
            )
            self._render()
            if self._restart_desktop_job is not None:
                try:
                    self.root.after_cancel(self._restart_desktop_job)
                except tk.TclError:
                    pass
            self._restart_desktop_job = self.root.after(
                250,
                lambda result=result: self._restart_codex_desktop(result),
            )
        except CodexAccountManagerError as error:
            self.status_message = str(error)
            self._render()

    def _restart_codex_desktop(self, result: Any = None) -> None:
        self._restart_desktop_job = None
        try:
            restart_codex_desktop(
                backup_destination=Path(result.desktop_session_backup_path)
                if result and result.desktop_session_backup_path
                else None,
                restore_source=Path(result.desktop_session_restore_path)
                if result and result.desktop_session_restore_path
                else None,
            )
        except CodexDesktopControlError as error:
            self.status_message = str(error)
            self._render()

    def open_folder(self, account: StoredAccount) -> None:
        os.startfile(account.codex_home_path)

    def prompt_nickname(self, account: StoredAccount) -> None:
        value = simpledialog.askstring(
            "Edit Account Alias" if account.nickname else "Set Account Alias",
            account.email_hint or account.display_name,
            initialvalue=account.nickname or "",
            parent=self.root,
        )
        if value is None:
            return
        self.nickname_drafts[account.id] = value.strip()
        self.update_nickname(account.id)

    def copy_email(self, account: StoredAccount) -> None:
        if not account.email_hint:
            return
        self.root.clipboard_clear()
        self.root.clipboard_append(account.email_hint)
        self.status_message = f"Copied {account.email_hint}."
        self._render()

    def _toggle_settings(self) -> None:
        self._set_settings_visible(not self.settings_visible)

    def _set_settings_visible(self, visible: bool) -> None:
        if visible == self.settings_visible:
            return
        if visible and self.search_visible:
            self.search_var.set("")
            self._set_search_visible(False)

        self.settings_visible = visible
        self.list_shell.pack_forget()
        self.settings_shell.pack_forget()
        if visible:
            self.startup_toggle.set_value(is_startup_enabled())
            self.auto_refresh_var.set(self._refresh_interval_label(self.app_settings.auto_refresh_minutes))
            if self.update_toggle is not None:
                self.update_toggle.set_value(self.app_settings.automatically_check_for_updates)
            self._sync_update_controls()
            self.settings_canvas.yview_moveto(0)
            self.settings_shell.pack(fill="both", expand=True, padx=8, pady=8)
        else:
            self.list_shell.pack(fill="both", expand=True, padx=8, pady=8)
        self._render()

    def _handle_escape(self) -> None:
        if self.settings_visible:
            self._set_settings_visible(False)
            return
        self._dismiss_search()

    def _set_launch_at_login(self, enabled: bool) -> None:
        self.startup_toggle.set_enabled(False)
        self.settings_status_message = ""
        try:
            set_startup_enabled(enabled)
        except AppSettingsError as error:
            self.settings_status_message = str(error)
        finally:
            self.startup_toggle.set_value(is_startup_enabled())
            self.startup_toggle.set_enabled(True)
        self._render()

    def _on_auto_refresh_selected(self, _: tk.Event[Any]) -> None:
        selected_label = self.auto_refresh_var.get()
        selected_interval = next(
            (
                interval
                for interval in AUTO_REFRESH_OPTIONS
                if self._refresh_interval_label(interval) == selected_label
            ),
            self.app_settings.auto_refresh_minutes,
        )
        previous_interval = self.app_settings.auto_refresh_minutes
        self.app_settings.auto_refresh_minutes = selected_interval
        self.settings_status_message = ""
        try:
            self.settings_store.save(self.app_settings)
        except OSError as error:
            self.app_settings.auto_refresh_minutes = previous_interval
            self.auto_refresh_var.set(self._refresh_interval_label(previous_interval))
            self.settings_status_message = f"Could not save settings: {error}"
        else:
            self._schedule_auto_refresh(replace_existing=True)
        self._render()

    def _set_automatic_updates(self, enabled: bool) -> None:
        if self.update_toggle is None:
            return
        previous_value = self.app_settings.automatically_check_for_updates
        self.update_toggle.set_enabled(False)
        self.settings_status_message = ""
        try:
            self.update_manager.set_automatic_checks(enabled)
            self.app_settings.automatically_check_for_updates = enabled
            self.settings_store.save(self.app_settings)
        except (OSError, UpdateManagerError) as error:
            self.app_settings.automatically_check_for_updates = previous_value
            self.update_toggle.set_value(previous_value)
            self.settings_status_message = str(error)
        finally:
            self.update_toggle.set_enabled(self.update_manager.is_available)
        self._render()

    def _check_for_updates(self) -> None:
        if self.check_update_button is None:
            return
        self.check_update_button.set_enabled(False)
        self.settings_status_message = "Checking for updates..."
        try:
            self.update_manager.check_now()
        except UpdateManagerError as error:
            self.settings_status_message = str(error)
            self.check_update_button.set_enabled(self.update_manager.is_available)
        self._render()

    def _sync_update_controls(self) -> None:
        available = self.update_manager.is_available
        if self.update_toggle is not None:
            self.update_toggle.set_value(self.app_settings.automatically_check_for_updates)
            self.update_toggle.set_enabled(available)
        if self.check_update_button is not None:
            self.check_update_button.set_enabled(available)

    def _apply_update_status(self, message: str) -> None:
        self.settings_status_message = message
        if self.check_update_button is not None:
            self.check_update_button.set_enabled(self.update_manager.is_available)
        self._render()

    @staticmethod
    def _refresh_interval_label(minutes: int) -> str:
        if minutes == 60:
            return "1 hour"
        return f"{minutes} minutes"

    def _open_external(self, url: str) -> None:
        self.settings_status_message = ""
        try:
            opened = webbrowser.open(url, new=2)
        except Exception as error:
            self.settings_status_message = f"Could not open the link: {error}"
        else:
            if not opened:
                self.settings_status_message = "Could not open the link."
        self._render()

    def _toggle_search(self) -> None:
        if self.settings_visible:
            return
        if self.search_visible and not self.search_var.get().strip():
            self._set_search_visible(False)
            return
        self._set_search_visible(True)

    def _dismiss_search(self) -> None:
        if not self.search_visible:
            return
        self.search_var.set("")
        self._set_search_visible(False)

    def _clear_search(self) -> None:
        self.search_var.set("")
        self._set_search_visible(False)

    def _set_search_visible(self, visible: bool) -> None:
        self.search_visible = visible
        self.brand.pack_forget()
        self.search_shell.pack_forget()
        if visible:
            self.search_shell.pack(side="left")
            self.search_entry.focus_set()
            self.search_entry.selection_range(0, "end")
        else:
            self.brand.pack(side="left")
            self.root.focus_set()
        self.search_button.set_selected(visible)

    @staticmethod
    def _system_prefers_dark() -> bool:
        if os.name != "nt":
            return True
        try:
            import winreg

            with winreg.OpenKey(
                winreg.HKEY_CURRENT_USER,
                r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
            ) as key:
                value, _ = winreg.QueryValueEx(key, "AppsUseLightTheme")
            return int(value) == 0
        except (OSError, ValueError):
            return True

    @staticmethod
    def _build_palette(dark: bool) -> dict[str, str]:
        if dark:
            return {
                "bg": "#18191c",
                "shell": "#202226",
                "panel": "#292b30",
                "panel_alt": "#303238",
                "selected": "#24342a",
                "list": "#24262a",
                "list_border": "#3d4046",
                "divider": "#35383d",
                "toolbar": "#2a2c31",
                "text": "#f1f2f4",
                "muted": "#a5a9b0",
                "disabled": "#71757d",
                "hairline": "#3c3f45",
                "tooltip": "#303238",
                "menu": "#292b30",
                "accent": "#30d158",
                "accent_soft": "#203928",
                "accent_line": "#315c3d",
                "success": "#30d158",
                "warning": "#ff9f0a",
                "yellow": "#ffd60a",
                "danger": "#ff453a",
                "neutral": "#8e8e93",
                "dark_icon": "#111215",
                "check": "#101812",
                "track": "#4a4d53",
                "metric": "#303238",
                "metric_border": "#45484e",
                "row_hover": "#2b2d32",
                "row_hover_border": "#41444a",
                "active_row": "#243129",
                "active_row_hover": "#29382f",
                "active_border": "#356242",
                "control": "#303238",
                "control_hover": "#3a3d43",
                "control_selected": "#3d4046",
                "control_border": "#50535a",
                "switch_off": "#555960",
                "switch_knob": "#f7f8f9",
                "active_control": "#223b2a",
                "warning_control": "#3b3021",
                "warning_control_hover": "#493a25",
                "warning_border": "#6a5129",
                "source_bg": "#303238",
                "source_text": "#b8bcc3",
                "source_border": "#45484e",
                "plan_pro_bg": "#3a335f",
                "plan_pro_text": "#c7bcff",
                "plan_pro_border": "#5c4e98",
                "plan_pro_lite_bg": "#293d5d",
                "plan_pro_lite_text": "#a8cbff",
                "plan_pro_lite_border": "#3f5f8f",
                "plan_plus_bg": "#243f39",
                "plan_plus_text": "#91dfcd",
                "plan_plus_border": "#37665b",
                "plan_team_bg": "#4a3038",
                "plan_team_text": "#f2aab9",
                "plan_team_border": "#774856",
                "plan_default_bg": "#373a40",
                "plan_default_text": "#c2c6cd",
                "plan_default_border": "#52565e",
            }

        return {
            "bg": "#e9ebee",
            "shell": "#f5f6f7",
            "panel": "#ffffff",
            "panel_alt": "#f0f1f3",
            "selected": "#eaf7ee",
            "list": "#f8f9fa",
            "list_border": "#d3d6da",
            "divider": "#e0e2e5",
            "toolbar": "#eceef0",
            "text": "#2d2f33",
            "muted": "#686c73",
            "disabled": "#a0a4aa",
            "hairline": "#d3d6da",
            "tooltip": "#ffffff",
            "menu": "#ffffff",
            "accent": "#157d40",
            "accent_soft": "#e5f5ea",
            "accent_line": "#a6d6b7",
            "success": "#22a447",
            "warning": "#a25800",
            "yellow": "#8a6a00",
            "danger": "#b92f27",
            "neutral": "#85888e",
            "dark_icon": "#15171a",
            "check": "#ffffff",
            "track": "#d7dade",
            "metric": "#f0f2f3",
            "metric_border": "#d2d5d9",
            "row_hover": "#eef0f2",
            "row_hover_border": "#d3d6da",
            "active_row": "#eaf7ee",
            "active_row_hover": "#e3f4e9",
            "active_border": "#a6d6b7",
            "control": "#f0f1f3",
            "control_hover": "#e2e5e8",
            "control_selected": "#dfe2e6",
            "control_border": "#c9cdd2",
            "switch_off": "#c5c9ce",
            "switch_knob": "#ffffff",
            "active_control": "#e1f4e7",
            "warning_control": "#fff4df",
            "warning_control_hover": "#f9e9cd",
            "warning_border": "#e3bd7c",
            "source_bg": "#eceef0",
            "source_text": "#656970",
            "source_border": "#d1d4d8",
            "plan_pro_bg": "#ebe7ff",
            "plan_pro_text": "#6452c5",
            "plan_pro_border": "#ccc3ff",
            "plan_pro_lite_bg": "#e5efff",
            "plan_pro_lite_text": "#4774b8",
            "plan_pro_lite_border": "#bfd3f3",
            "plan_plus_bg": "#e1f3ee",
            "plan_plus_text": "#247765",
            "plan_plus_border": "#b8ddd4",
            "plan_team_bg": "#f7e6ea",
            "plan_team_text": "#9a4c5c",
            "plan_team_border": "#e7c0c9",
            "plan_default_bg": "#eceef0",
            "plan_default_text": "#62666d",
            "plan_default_border": "#d1d4d8",
        }

    def _configure_styles(self) -> None:
        style = ttk.Style()
        if "clam" in style.theme_names():
            style.theme_use("clam")
        style.configure(
            "CodexVitals.TCombobox",
            fieldbackground=self.palette["control"],
            background=self.palette["control"],
            foreground=self.palette["text"],
            arrowcolor=self.palette["muted"],
            bordercolor=self.palette["control_border"],
            lightcolor=self.palette["control"],
            darkcolor=self.palette["control"],
            padding=(8, 5),
            relief="flat",
        )
        style.map(
            "CodexVitals.TCombobox",
            fieldbackground=[("readonly", self.palette["control"])],
            foreground=[("readonly", self.palette["text"])],
            selectbackground=[("readonly", self.palette["control"])],
            selectforeground=[("readonly", self.palette["text"])],
        )
        self.root.option_add("*TCombobox*Listbox.background", self.palette["panel"])
        self.root.option_add("*TCombobox*Listbox.foreground", self.palette["text"])
        self.root.option_add("*TCombobox*Listbox.selectBackground", self.palette["active_control"])
        self.root.option_add("*TCombobox*Listbox.selectForeground", self.palette["text"])

    def _configure_fonts(self) -> None:
        families = {name.casefold(): name for name in tkfont.families(self.root)}

        def pick(candidates: list[str], fallback: str) -> str:
            for candidate in candidates:
                match = families.get(candidate.casefold())
                if match:
                    return match
            return fallback

        self.font_family_display = pick(
            [
                "Aptos Display",
                "Segoe UI Variable Display Semib",
                "Segoe UI Variable Display",
                "Bahnschrift SemiBold",
                "Segoe UI Semibold",
                "Segoe UI",
            ],
            "Segoe UI",
        )
        self.font_family_text = pick(
            [
                "Aptos",
                "Segoe UI Variable Text",
                "Segoe UI Variable Small",
                "Segoe UI",
            ],
            "Segoe UI",
        )
        self.font_family_mono = pick(
            [
                "Cascadia Code",
                "Consolas",
            ],
            "Consolas",
        )
        self.font_family_icon = pick(
            [
                "Segoe Fluent Icons",
                "Segoe MDL2 Assets",
            ],
            self.font_family_text,
        )

        self.fonts = {
            "title": (self.font_family_display, 15, "bold"),
            "headline": (self.font_family_display, 12, "bold"),
            "body": (self.font_family_text, 10),
            "body_small": (self.font_family_text, 9),
            "caption": (self.font_family_text, 8),
            "label": (self.font_family_text, 8, "bold"),
            "button": (self.font_family_text, 9, "bold"),
            "button_small": (self.font_family_text, 8, "bold"),
            "metric": (self.font_family_display, 12, "bold"),
            "mono": (self.font_family_mono, 8),
            "icon": (self.font_family_icon, 10),
            "icon_small": (self.font_family_icon, 9),
            "row_title": (self.font_family_text, 10, "bold"),
            "row_meta": (self.font_family_text, 9),
            "badge": (self.font_family_text, 8, "bold"),
            "chip": (self.font_family_text, 8, "bold"),
            "metric_label": (self.font_family_text, 8, "bold"),
            "metric_value": (self.font_family_text, 9, "bold"),
            "metric_reset": (self.font_family_mono, 8),
            "action": (self.font_family_text, 8, "bold"),
        }

        self.icons = {
            "search": "\ue721" if self.font_family_icon != self.font_family_text else "⌕",
            "add": "\ue710" if self.font_family_icon != self.font_family_text else "+",
            "refresh": "\ue72c" if self.font_family_icon != self.font_family_text else "↻",
            "folder": "\ue838" if self.font_family_icon != self.font_family_text else "⌂",
            "trash": "\ue74d" if self.font_family_icon != self.font_family_text else "×",
            "save": "\ue74e" if self.font_family_icon != self.font_family_text else "•",
            "spark": "\ue945" if self.font_family_icon != self.font_family_text else "•",
            "settings": "\ue713" if self.font_family_icon != self.font_family_text else "\u2699",
            "back": "\ue72b" if self.font_family_icon != self.font_family_text else "<",
            "external": "\ue8a7" if self.font_family_icon != self.font_family_text else "\u2197",
            "home": "\ue80f" if self.font_family_icon != self.font_family_text else "H",
            "code": "\ue943" if self.font_family_icon != self.font_family_text else "<>",
            "mail": "\ue715" if self.font_family_icon != self.font_family_text else "@",
            "power": "\ue7e8" if self.font_family_icon != self.font_family_text else "x",
            "close": "\ue711" if self.font_family_icon != self.font_family_text else "x",
        }
        if self.font_family_icon == self.font_family_text:
            self.icons["search"] = "\u2315"
            self.icons["refresh"] = "\u21bb"
            self.icons["folder"] = "\u25a3"
            self.icons["trash"] = "\u2715"
            self.icons["save"] = "\u25cf"
            self.icons["spark"] = "\u2736"
            self.icons["settings"] = "\u2699"
            self.icons["back"] = "<"
            self.icons["external"] = "\u2197"
            self.icons["home"] = "H"
            self.icons["code"] = "<>"
            self.icons["mail"] = "@"
            self.icons["power"] = "x"
            self.icons["close"] = "x"
        self.icons["metric_accounts"] = "\u25a6"
        self.icons["metric_live"] = "\u25c9"
        self.icons["metric_critical"] = "\u26a0"

    def _build_ui(self) -> None:
        outer = tk.Frame(self.root, bg=self.palette["bg"])
        outer.pack(fill="both", expand=True, padx=10, pady=10)

        self.shell = tk.Frame(
            outer,
            bg=self.palette["shell"],
            highlightthickness=1,
            highlightbackground=self.palette["hairline"],
        )
        self.shell.pack(fill="both", expand=True)

        header = tk.Frame(self.shell, bg=self.palette["shell"], padx=14, pady=9)
        header.pack(fill="x")

        self.header_left = tk.Frame(header, bg=self.palette["shell"])
        self.header_left.pack(side="left", fill="x", expand=True)

        self.brand = tk.Frame(self.header_left, bg=self.palette["shell"])
        self.brand.pack(side="left")
        self.brand_icon_image = ImageTk.PhotoImage(self._create_icon_image("neutral", 28))
        self.brand_icon_label = tk.Label(
            self.brand,
            image=self.brand_icon_image,
            bg=self.palette["shell"],
            bd=0,
        )
        self.brand_icon_label.pack(side="left")

        brand_text = tk.Frame(self.brand, bg=self.palette["shell"])
        brand_text.pack(side="left", padx=(9, 0))
        self.title_label = tk.Label(
            brand_text,
            text=APP_DISPLAY_NAME,
            bg=self.palette["shell"],
            fg=self.palette["text"],
            font=self.fonts["title"],
            anchor="w",
        )
        self.title_label.pack(anchor="w")
        self.subtitle_label = tk.Label(
            brand_text,
            text="",
            bg=self.palette["shell"],
            fg=self.palette["muted"],
            font=self.fonts["caption"],
            anchor="w",
        )
        self.subtitle_label.pack(anchor="w")

        self.search_shell = tk.Frame(
            self.header_left,
            bg=self.palette["metric"],
            highlightthickness=1,
            highlightbackground=self.palette["metric_border"],
            padx=8,
            pady=5,
        )
        tk.Label(
            self.search_shell,
            text=self.icons["search"],
            bg=self.palette["metric"],
            fg=self.palette["muted"],
            font=self.fonts["icon_small"],
        ).pack(side="left", padx=(0, 6))
        self.search_entry = tk.Entry(
            self.search_shell,
            textvariable=self.search_var,
            relief="flat",
            bd=0,
            width=28,
            bg=self.palette["metric"],
            fg=self.palette["text"],
            insertbackground=self.palette["text"],
            selectbackground=self.palette["active_border"],
            font=self.fonts["body"],
        )
        self.search_entry.pack(side="left")
        self.search_clear_button = IconButton(
            self.search_shell,
            icon=self.icons["close"],
            command=self._clear_search,
            palette=self.palette,
            font=self.fonts["icon_small"],
            tooltip="Clear search",
            size=24,
        )
        self.search_clear_button.pack(side="left", padx=(4, 0))

        toolbar = tk.Canvas(
            header,
            width=154,
            height=34,
            bg=self.palette["shell"],
            highlightthickness=0,
            bd=0,
        )
        toolbar.pack(side="right")
        draw_rounded_rectangle(
            toolbar,
            1,
            1,
            153,
            33,
            16,
            fill=self.palette["toolbar"],
            outline=self.palette["control_border"],
        )
        controls = tk.Frame(toolbar, bg=self.palette["toolbar"], width=144, height=28)
        controls.pack_propagate(False)
        toolbar.create_window(5, 3, window=controls, anchor="nw", width=144, height=28)

        self.search_button = IconButton(
            controls,
            icon=self.icons["search"],
            command=self._toggle_search,
            palette=self.palette,
            font=self.fonts["icon"],
            tooltip="Search accounts",
        )
        self.search_button.pack(side="left")
        self.add_button = IconButton(
            controls,
            icon=self.icons["add"],
            command=self.start_or_cancel_add_account,
            palette=self.palette,
            font=self.fonts["icon"],
            tooltip="Add account",
            tone=self.palette["success"],
        )
        self.add_button.pack(side="left", padx=(1, 0))
        self.refresh_button = IconButton(
            controls,
            icon=self.icons["refresh"],
            command=self.refresh_all,
            palette=self.palette,
            font=self.fonts["icon"],
            tooltip="Refresh all accounts",
        )
        self.refresh_button.pack(side="left", padx=(1, 0))
        self.settings_button = IconButton(
            controls,
            icon=self.icons["settings"],
            command=self._toggle_settings,
            palette=self.palette,
            font=self.fonts["icon"],
            tooltip="Settings",
        )
        self.settings_button.pack(side="left", padx=(1, 0))
        self.power_button = IconButton(
            controls,
            icon=self.icons["power"],
            command=self.quit,
            palette=self.palette,
            font=self.fonts["icon"],
            tooltip=f"Quit {APP_DISPLAY_NAME}",
        )
        self.power_button.pack(side="left", padx=(1, 0))

        tk.Frame(self.shell, bg=self.palette["divider"], height=1).pack(fill="x")

        self.list_shell = tk.Frame(
            self.shell,
            bg=self.palette["list"],
            highlightthickness=1,
            highlightbackground=self.palette["list_border"],
        )
        self.list_shell.pack(fill="both", expand=True, padx=8, pady=8)

        self.canvas = tk.Canvas(
            self.list_shell,
            bg=self.palette["list"],
            highlightthickness=0,
            bd=0,
        )
        self.canvas.pack(side="left", fill="both", expand=True)

        scrollbar = DarkScrollbar(
            self.list_shell,
            command=self.canvas.yview,
            palette=self.palette,
            width=9,
        )
        scrollbar.pack(side="right", fill="y")
        self.canvas.configure(yscrollcommand=scrollbar.set)
        self.scrollbar = scrollbar

        self.cards_frame = tk.Frame(self.canvas, bg=self.palette["list"])
        self.cards_window = self.canvas.create_window((0, 0), window=self.cards_frame, anchor="nw")
        self.cards_frame.bind("<Configure>", self._on_cards_configure)
        self.canvas.bind("<Configure>", self._on_canvas_configure)
        self.canvas.bind_all("<MouseWheel>", self._on_mousewheel)

        self._build_settings_ui()

    def _build_settings_ui(self) -> None:
        self.settings_shell = tk.Frame(
            self.shell,
            bg=self.palette["list"],
            highlightthickness=1,
            highlightbackground=self.palette["list_border"],
        )
        self.settings_canvas = tk.Canvas(
            self.settings_shell,
            bg=self.palette["list"],
            highlightthickness=0,
            bd=0,
        )
        self.settings_canvas.pack(side="left", fill="both", expand=True)
        self.settings_scrollbar = DarkScrollbar(
            self.settings_shell,
            command=self.settings_canvas.yview,
            palette=self.palette,
            width=9,
        )
        self.settings_scrollbar.pack(side="right", fill="y")
        self.settings_canvas.configure(yscrollcommand=self.settings_scrollbar.set)

        self.settings_content = tk.Frame(self.settings_canvas, bg=self.palette["list"])
        self.settings_window = self.settings_canvas.create_window(
            (0, 0),
            window=self.settings_content,
            anchor="nw",
        )
        self.settings_content.bind("<Configure>", self._on_settings_content_configure)
        self.settings_canvas.bind("<Configure>", self._on_settings_canvas_configure)

        settings_header = tk.Frame(self.settings_content, bg=self.palette["list"])
        settings_header.pack(fill="x", padx=4, pady=(5, 10))
        back_button = IconButton(
            settings_header,
            icon=self.icons["back"],
            command=lambda: self._set_settings_visible(False),
            palette=self.palette,
            font=self.fonts["icon"],
            tooltip="Back to accounts",
            size=30,
        )
        back_button.pack(side="left")
        tk.Label(
            settings_header,
            text="Settings",
            bg=self.palette["list"],
            fg=self.palette["text"],
            font=self.fonts["headline"],
        ).pack(side="left", padx=(9, 0))

        self._settings_section_label("GENERAL")
        general_panel = self._create_settings_panel(height=112)

        launch_row = tk.Frame(general_panel, bg=self.palette["panel"], height=48)
        launch_row.pack(fill="x")
        launch_row.pack_propagate(False)
        tk.Label(
            launch_row,
            text="Launch at Login",
            bg=self.palette["panel"],
            fg=self.palette["text"],
            font=self.fonts["body"],
        ).pack(side="left", padx=(2, 0))
        self.startup_toggle = ToggleSwitch(
            launch_row,
            value=is_startup_enabled(),
            command=self._set_launch_at_login,
            palette=self.palette,
            tooltip="Launch Codex Vitals when you sign in",
        )
        self.startup_toggle.pack(side="right", padx=(0, 2))

        tk.Frame(general_panel, bg=self.palette["divider"], height=1).pack(fill="x")

        refresh_row = tk.Frame(general_panel, bg=self.palette["panel"], height=48)
        refresh_row.pack(fill="x")
        refresh_row.pack_propagate(False)
        tk.Label(
            refresh_row,
            text="Auto Refresh",
            bg=self.palette["panel"],
            fg=self.palette["text"],
            font=self.fonts["body"],
        ).pack(side="left", padx=(2, 0))
        self.auto_refresh_combo = ttk.Combobox(
            refresh_row,
            textvariable=self.auto_refresh_var,
            values=[self._refresh_interval_label(value) for value in AUTO_REFRESH_OPTIONS],
            state="readonly",
            width=12,
            justify="center",
            font=self.fonts["body_small"],
            style="CodexVitals.TCombobox",
        )
        self.auto_refresh_combo.pack(side="right", padx=(0, 2))
        self.auto_refresh_combo.bind("<<ComboboxSelected>>", self._on_auto_refresh_selected)

        self._settings_section_label("ABOUT")
        about_panel = self._create_settings_panel(height=124)
        about_row = tk.Frame(about_panel, bg=self.palette["panel"], height=48)
        about_row.pack(fill="x")
        about_row.pack_propagate(False)
        tk.Label(
            about_row,
            text="Current Version",
            bg=self.palette["panel"],
            fg=self.palette["text"],
            font=self.fonts["body"],
        ).pack(side="left", padx=(2, 0))
        tk.Label(
            about_row,
            text=f"v{APP_VERSION}",
            bg=self.palette["panel_alt"],
            fg=self.palette["muted"],
            font=self.fonts["mono"],
            padx=9,
            pady=4,
            highlightthickness=1,
            highlightbackground=self.palette["hairline"],
        ).pack(side="right", padx=(0, 2))

        tk.Frame(about_panel, bg=self.palette["divider"], height=1).pack(fill="x")
        self.ramter_studio_logo_image = ImageTk.PhotoImage(
            build_ramter_studio_logo(150, 24, self.palette["text"]),
            master=self.root,
        )
        studio_link = StudioLogoLink(
            about_panel,
            logo=self.ramter_studio_logo_image,
            command=lambda: self._open_external(RAMTER_STUDIO_URL),
            palette=self.palette,
            caption_font=self.fonts["caption"],
            icon_font=self.fonts["icon_small"],
            external_icon=self.icons["external"],
        )
        studio_link.pack(fill="x")

        self._settings_section_label("UPDATES")
        if self.update_manager.is_store_build:
            updates_panel = self._create_settings_panel(height=64)
            store_row = tk.Frame(updates_panel, bg=self.palette["panel"], height=48)
            store_row.pack(fill="x")
            store_row.pack_propagate(False)
            tk.Label(
                store_row,
                text="Updates",
                bg=self.palette["panel"],
                fg=self.palette["text"],
                font=self.fonts["body"],
            ).pack(side="left", padx=(2, 0))
            tk.Label(
                store_row,
                text="Microsoft Store",
                bg=self.palette["panel_alt"],
                fg=self.palette["muted"],
                font=self.fonts["body_small"],
                padx=9,
                pady=4,
                highlightthickness=1,
                highlightbackground=self.palette["hairline"],
            ).pack(side="right", padx=(0, 2))
        else:
            updates_panel = self._create_settings_panel(height=112)
            automatic_row = tk.Frame(updates_panel, bg=self.palette["panel"], height=48)
            automatic_row.pack(fill="x")
            automatic_row.pack_propagate(False)
            tk.Label(
                automatic_row,
                text="Automatically Check",
                bg=self.palette["panel"],
                fg=self.palette["text"],
                font=self.fonts["body"],
            ).pack(side="left", padx=(2, 0))
            self.update_toggle = ToggleSwitch(
                automatic_row,
                value=self.app_settings.automatically_check_for_updates,
                command=self._set_automatic_updates,
                palette=self.palette,
                tooltip="Check for Codex Vitals updates once per day",
            )
            self.update_toggle.pack(side="right", padx=(0, 2))

            tk.Frame(updates_panel, bg=self.palette["divider"], height=1).pack(fill="x")

            check_row = tk.Frame(updates_panel, bg=self.palette["panel"], height=48)
            check_row.pack(fill="x")
            check_row.pack_propagate(False)
            tk.Label(
                check_row,
                text="Software Update",
                bg=self.palette["panel"],
                fg=self.palette["text"],
                font=self.fonts["body"],
            ).pack(side="left", padx=(2, 0))
            self.check_update_button = self._make_button(
                check_row,
                "Check Now",
                self._check_for_updates,
                "surface_small",
                icon=self.icons["refresh"],
            )
            self.check_update_button.pack(side="right", padx=(0, 2), pady=8)

        self._settings_section_label("LINKS")
        links_panel = self._create_settings_panel(height=68)
        links_row = tk.Frame(links_panel, bg=self.palette["panel"], height=52)
        links_row.pack(fill="x")
        links_row.pack_propagate(False)
        link_specs = [
            ("Homepage", HOMEPAGE_URL, self.icons["home"]),
            ("GitHub", GITHUB_URL, self.icons["code"]),
            ("Feedback", FEEDBACK_URL, self.icons["mail"]),
        ]
        for index, (label, url, icon) in enumerate(link_specs):
            button = self._make_button(
                links_row,
                label,
                lambda target=url: self._open_external(target),
                "surface_small",
                icon=icon,
            )
            button.pack(side="left", padx=(0 if index == 0 else 8, 0), pady=9)

        self.settings_status_label = tk.Label(
            self.settings_content,
            text="",
            bg=self.palette["list"],
            fg=self.palette["warning"],
            font=self.fonts["caption"],
            anchor="w",
            justify="left",
            wraplength=500,
        )
        self.settings_status_label.pack(fill="x", padx=6, pady=(8, 12))

    def _settings_section_label(self, text: str) -> None:
        tk.Label(
            self.settings_content,
            text=text,
            bg=self.palette["list"],
            fg=self.palette["muted"],
            font=self.fonts["label"],
            anchor="w",
        ).pack(fill="x", padx=7, pady=(3, 5))

    def _create_settings_panel(self, *, height: int) -> tk.Frame:
        panel_canvas = tk.Canvas(
            self.settings_content,
            height=height,
            bg=self.palette["list"],
            highlightthickness=0,
            bd=0,
        )
        panel_canvas.pack(fill="x", pady=(0, 8))
        inner = tk.Frame(panel_canvas, bg=self.palette["panel"])
        inner_window = panel_canvas.create_window(12, 8, window=inner, anchor="nw")

        def redraw(event: tk.Event[Any]) -> None:
            panel_canvas.delete("panel_background")
            background = draw_rounded_rectangle(
                panel_canvas,
                1,
                1,
                max(2, event.width - 2),
                height - 2,
                11,
                fill=self.palette["panel"],
                outline=self.palette["hairline"],
            )
            panel_canvas.addtag_withtag("panel_background", background)
            panel_canvas.tag_lower(background)
            panel_canvas.coords(inner_window, 12, 8)
            panel_canvas.itemconfigure(inner_window, width=max(1, event.width - 24), height=height - 16)

        panel_canvas.bind("<Configure>", redraw)
        return inner

    def _setup_tray_icon(self) -> None:
        self.tray_icon: pystray.Icon | None = None
        menu = pystray.Menu(
            pystray.MenuItem(
                f"Open {APP_DISPLAY_NAME}",
                lambda icon, item: self.root.after(0, self.show_window),
                default=True,
            ),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem(
                lambda _: "Hide Window" if self.root.state() != "withdrawn" else "Show Window",
                lambda icon, item: self.root.after(0, self._toggle_window),
            ),
            pystray.MenuItem("Refresh All", lambda icon, item: self.root.after(0, self.refresh_all)),
            pystray.MenuItem("Add Account", lambda icon, item: self.root.after(0, self.start_add_account)),
            pystray.MenuItem("Quit", lambda icon, item: self.root.after(0, self.quit)),
        )
        self.tray_icon = pystray.Icon(
            APP_INTERNAL_NAME,
            self._create_icon_image("neutral", 64),
            APP_DISPLAY_NAME,
            menu,
        )
        self.tray_icon.run_detached()

    def _set_window_icon(self) -> None:
        self.window_icon_images = [
            ImageTk.PhotoImage(self._create_icon_image("neutral", size))
            for size in (16, 24, 32, 48, 64)
        ]
        self.root.iconphoto(True, *self.window_icon_images)

    def _toggle_window(self) -> None:
        if self.root.state() == "withdrawn":
            self.show_window()
        else:
            self.hide_window()

    def _load_initial_state(self) -> None:
        try:
            loaded_accounts, self.removed_accounts = self.account_store.load_account_list()
            loaded_accounts = [account for account in loaded_accounts if not self._is_removed(account)]
            stored_accounts = [account for account in loaded_accounts if account.source is not StoredAccountSource.AMBIENT]
            discovered_accounts = self.account_manager.discover_managed_accounts(loaded_accounts)
            ambient_account = self.account_manager.discover_ambient_account(loaded_accounts)
            incoming_accounts = list(discovered_accounts)
            if ambient_account is not None:
                incoming_accounts.insert(0, ambient_account)
            incoming_accounts = [account for account in incoming_accounts if not self._is_removed(account)]

            self.accounts = self.account_store.merge(stored_accounts, incoming_accounts)
            if self.accounts != loaded_accounts:
                self.account_store.save_accounts(self.accounts, self.removed_accounts)
        except Exception as error:
            self.status_message = str(error)
            self.accounts = []

        try:
            persisted = self.snapshot_store.load()
            valid_ids = {account.id for account in self.accounts}
            self.runtime_states = {
                account_id: AccountRuntimeState(snapshot=snapshot)
                for account_id, snapshot in persisted.items()
                if account_id in valid_ids
            }
        except Exception as error:
            self.status_message = str(error)
            self.runtime_states = {}

        for account in self.accounts:
            self.nickname_drafts[account.id] = account.nickname or ""

        self._mark_accounts_dirty()
        self._mark_runtime_dirty()
        self._ensure_selection()
        self._refresh_active_identity()

    def _submit_future(self, future: Future[Any], event_name: str, *metadata: Any) -> None:
        def callback(completed: Future[Any]) -> None:
            try:
                result = completed.result()
                self.events.put((event_name, *metadata, result, None))
            except Exception as error:
                self.events.put((event_name, *metadata, None, error))

        future.add_done_callback(callback)

    def _process_event_queue(self) -> None:
        self._queue_poll_job = None
        processed = 0
        while processed < 100:
            try:
                event = self.events.get_nowait()
            except queue.Empty:
                break

            processed += 1
            name = event[0]
            if name == "refresh_result":
                _, account_id, from_group, snapshot, error = event
                self._apply_refresh_result(account_id, from_group, snapshot, error)
            elif name == "add_account_result":
                _, account, error = event
                self._apply_add_account_result(account, error)
            elif name == "reauth_result":
                _, account_id, account, error = event
                self._apply_reauth_result(account_id, account, error)
            elif name == "update_status":
                _, message = event
                self._apply_update_status(message)
            elif name == "update_shutdown":
                self.quit()
                return

        if not self._quitting:
            self._queue_poll_job = self.root.after(self.QUEUE_POLL_MS, self._process_event_queue)

    def _apply_refresh_result(
        self,
        account_id: UUID,
        from_group: bool,
        snapshot: AccountUsageSnapshot | None,
        error: Exception | None,
    ) -> None:
        state = self.runtime_states.setdefault(account_id, AccountRuntimeState())
        state.is_loading = False

        if snapshot is not None:
            state.snapshot = snapshot
            state.error_message = None
            self.runtime_states[account_id] = state
            self._update_account_metadata(account_id, snapshot)
        else:
            state.snapshot = None
            state.error_message = str(error) if error else "Unknown refresh error."
            self.runtime_states[account_id] = state

        self._mark_runtime_dirty()
        if from_group:
            self._group_refresh_pending = max(0, self._group_refresh_pending - 1)
            self._group_refresh_flush_pending = True
            if self._group_refresh_pending == 0:
                self.is_refreshing_all = False
                self._flush_group_refresh_updates()
            else:
                self._schedule_group_refresh_flush()
            return

        self._persist_snapshots_silently()
        self._render()

    def _apply_add_account_result(self, account: StoredAccount | None, error: Exception | None) -> None:
        self.is_adding_account = False
        self._add_handle = None

        if account is not None:
            self._restore_removed_account(account)
            self.accounts = self.account_store.merge(self.accounts, [account])
            self.account_store.save_accounts(self.accounts, self.removed_accounts)
            self._mark_accounts_dirty()
            matched = next((candidate for candidate in self.accounts if candidate.matches(account)), account)
            self.selected_account_id = matched.id
            self.nickname_drafts[matched.id] = matched.nickname or ""
            self.status_message = f"{matched.display_name} added."
            self.refresh_account(matched)
        else:
            self.status_message = str(error) if error else "Account setup failed."
            self._render()

    def _apply_reauth_result(
        self,
        original_account_id: UUID,
        account: StoredAccount | None,
        error: Exception | None,
    ) -> None:
        self.reauthenticating_account_id = None
        self._reauth_handle = None

        if account is not None:
            self._restore_removed_account(account)
            self.accounts = self.account_store.merge(self.accounts, [account])
            self.account_store.save_accounts(self.accounts, self.removed_accounts)
            self._mark_accounts_dirty()
            self.status_message = f"{account.display_name} reauthenticated."
            refreshed = next((candidate for candidate in self.accounts if candidate.id == original_account_id), None)
            if refreshed is not None:
                self.refresh_account(refreshed)
            else:
                self._render()
            return

        self.status_message = str(error) if error else "Reauthentication failed."
        self._render()

    def _update_account_metadata(self, account_id: UUID, snapshot: AccountUsageSnapshot) -> None:
        account = next((candidate for candidate in self.accounts if candidate.id == account_id), None)
        if account is None:
            return

        did_change = False
        normalized_email = snapshot.email.strip().lower() if snapshot.email else None
        if normalized_email and account.email_hint != normalized_email:
            account.email_hint = normalized_email
            did_change = True

        if snapshot.provider_account_id and account.provider_account_id != snapshot.provider_account_id:
            account.provider_account_id = snapshot.provider_account_id
            did_change = True

        if did_change:
            self._mark_accounts_dirty()
            self._persist_accounts_silently()

    def _persist_accounts_silently(self) -> None:
        try:
            self.account_store.save_accounts(self.accounts, self.removed_accounts)
        except Exception as error:
            self.status_message = str(error)

    def _persist_snapshots_silently(self) -> None:
        snapshots = {
            account_id: state.snapshot
            for account_id, state in self.runtime_states.items()
            if state.snapshot is not None
        }
        try:
            self.snapshot_store.save(snapshots)
        except Exception as error:
            self.status_message = str(error)

    def _schedule_group_refresh_flush(self) -> None:
        if self._group_refresh_flush_job is not None:
            return
        self._group_refresh_flush_job = self.root.after(
            self.GROUP_REFRESH_FLUSH_MS,
            self._flush_group_refresh_updates,
        )

    def _flush_group_refresh_updates(self) -> None:
        scheduled_job = self._group_refresh_flush_job
        self._group_refresh_flush_job = None
        if scheduled_job is not None:
            try:
                self.root.after_cancel(scheduled_job)
            except tk.TclError:
                pass

        if not self._group_refresh_flush_pending:
            return

        self._group_refresh_flush_pending = False
        self._persist_snapshots_silently()
        self._render()

    def _ensure_selection(self) -> None:
        valid_ids = {account.id for account in self.accounts}
        if self.selected_account_id in valid_ids:
            return
        presentation = self._build_presentation_state()
        if len(presentation.filtered_accounts) == 1:
            self.selected_account_id = presentation.filtered_accounts[0].id
        else:
            self.selected_account_id = None

    def _refresh_active_identity(self) -> None:
        self.active_identity = self.account_manager.load_active_identity()

    def _is_removed(self, account: StoredAccount) -> bool:
        return any(removed.matches(account) for removed in self.removed_accounts)

    def _restore_removed_account(self, account: StoredAccount) -> None:
        self.removed_accounts = [removed for removed in self.removed_accounts if not removed.matches(account)]

    def _requires_reauthentication(self, account_id: UUID) -> bool:
        state = self.runtime_states.get(account_id)
        if state is None or not state.error_message:
            return False

        message = state.error_message.lower()
        return "refresh token" in message and "sign in again" in message

    def _replace_or_append_account(self, account: StoredAccount) -> None:
        replaced = False
        for index, existing in enumerate(self.accounts):
            if existing.id == account.id or existing.matches(account):
                self.accounts[index] = account
                replaced = True
                break
        if not replaced:
            self.accounts.append(account)
        self._mark_accounts_dirty()
        self._persist_accounts_silently()

    def _is_active_account(self, account: StoredAccount) -> bool:
        return is_active_account(account, self.active_identity)

    def _can_switch_account(self, account: StoredAccount) -> bool:
        if self._is_active_account(account):
            return False
        return (Path(account.codex_home_path) / "auth.json").exists()

    def _schedule_auto_refresh(self, *, replace_existing: bool = False) -> None:
        if self._quitting:
            return
        if self._auto_refresh_job is not None:
            if not replace_existing:
                return
            try:
                self.root.after_cancel(self._auto_refresh_job)
            except tk.TclError:
                pass
            self._auto_refresh_job = None
        delay_ms = self.app_settings.auto_refresh_minutes * 60 * 1000
        self._auto_refresh_job = self.root.after(delay_ms, self._auto_refresh_tick)

    def _auto_refresh_tick(self) -> None:
        self._auto_refresh_job = None
        if not self._quitting:
            self.refresh_all()
            self._schedule_auto_refresh()

    @property
    def filtered_accounts(self) -> list[StoredAccount]:
        return self._build_presentation_state().filtered_accounts

    @property
    def account_count(self) -> int:
        return self._build_presentation_state().account_count

    @property
    def low_quota_count(self) -> int:
        return self._build_presentation_state().low_quota_count

    @property
    def usable_quota_count(self) -> int:
        return self._build_presentation_state().usable_quota_count

    @property
    def menu_bar_quota_state(self) -> str:
        return self._build_presentation_state().menu_bar_quota_state

    def _render(self) -> None:
        if self._quitting or self._render_job is not None:
            return
        try:
            self._render_job = self.root.after_idle(self._render_now)
        except tk.TclError:
            self._render_job = None

    def _render_now(self) -> None:
        self._render_job = None
        presentation = self._build_presentation_state()
        header_source = "Settings" if self.settings_visible else self._header_status_text(presentation)
        header_status = self._ellipsize(
            header_source,
            self.fonts["caption"],
            max(180, self._header_wrap_width() - 180),
        )
        self.subtitle_label.configure(text=header_status)
        self.add_button.set_icon(self.icons["close"] if self.is_adding_account else self.icons["add"])
        self.add_button.set_selected(self.is_adding_account)
        self.add_button.set_tone(self.palette["warning"] if self.is_adding_account else self.palette["success"])
        self.search_button.set_enabled(not self.settings_visible)
        self.add_button.set_enabled(not self.settings_visible)
        self.refresh_button.set_enabled(not self.settings_visible and not self.is_refreshing_all)
        self.refresh_button.set_tone(self.palette["success"] if self.is_refreshing_all else None)
        self.search_button.set_selected(self.search_visible)
        self.settings_button.set_selected(self.settings_visible)
        self.brand_icon_image = ImageTk.PhotoImage(
            self._create_icon_image(presentation.menu_bar_quota_state, 28)
        )
        self.brand_icon_label.configure(image=self.brand_icon_image)
        if self.settings_visible:
            self.settings_status_label.configure(text=self.settings_status_message)
        else:
            self._render_cards(presentation)
        self._update_tray(presentation)

    def _render_metrics(self, presentation: PresentationState) -> None:
        if not self._metric_value_labels:
            for column in range(3):
                self.metrics_frame.grid_columnconfigure(column, weight=1, uniform="metrics")

            metrics = [
                ("accounts", "Accounts", self.icons["metric_accounts"], self.palette["neutral"]),
                ("live", "Live", self.icons["metric_live"], self.palette["success"]),
                ("critical", "Critical", self.icons["metric_critical"], self.palette["warning"]),
            ]
            for index, (key, label, icon, tone) in enumerate(metrics):
                tile, value_label = self._build_metric_tile(self.metrics_frame, label, "0", icon, tone)
                tile.grid(row=0, column=index, sticky="nsew", padx=(0, 6 if index < len(metrics) - 1 else 0))
                self._metric_value_labels[key] = value_label

        self._metric_value_labels["accounts"].configure(text=str(presentation.account_count))
        self._metric_value_labels["live"].configure(text=str(presentation.usable_quota_count))
        self._metric_value_labels["critical"].configure(text=str(presentation.low_quota_count))

    def _build_metric_tile(
        self,
        parent: tk.Widget,
        label: str,
        value: str,
        icon: str,
        tone: str,
    ) -> tuple[tk.Frame, tk.Label]:
        tile = tk.Frame(
            parent,
            bg=self.palette["panel"],
            highlightthickness=1,
            highlightbackground=self.palette["hairline"],
            padx=10,
            pady=9,
        )

        top = tk.Frame(tile, bg=self.palette["panel"])
        top.pack(fill="x")

        badge = tk.Frame(
            top,
            bg=self.palette["panel_alt"],
            highlightthickness=1,
            highlightbackground=self.palette["hairline"],
            width=24,
            height=24,
        )
        badge.pack(side="left")
        badge.pack_propagate(False)

        tk.Label(
            badge,
            text=icon,
            bg=self.palette["panel_alt"],
            fg=tone,
            font=self.fonts["label"],
        ).pack(expand=True)

        tk.Label(
            top,
            text=label,
            bg=self.palette["panel"],
            fg=self.palette["muted"],
            font=self.fonts["caption"],
        ).pack(side="left", padx=(8, 0))

        value_label = tk.Label(
            tile,
            text=value,
            bg=self.palette["panel"],
            fg=self.palette["text"],
            font=self.fonts["metric"],
        )
        value_label.pack(anchor="w", pady=(8, 0))
        return tile, value_label

    def _render_cards(self, presentation: PresentationState) -> None:
        self._cancel_cards_render_job()
        self._cards_render_token += 1
        for child in self.cards_frame.winfo_children():
            child.destroy()

        accounts = presentation.filtered_accounts
        if not accounts:
            self._render_empty_state(presentation.search_query)
            return

        for account in accounts:
            state = self.runtime_states.get(account.id, AccountRuntimeState())
            row = AccountRow(
                self.cards_frame,
                account=account,
                state=state,
                palette=self.palette,
                fonts=self.fonts,
                is_active=self._is_active_account(account),
                can_switch=self._can_switch_account(account),
                needs_reauthentication=self._requires_reauthentication(account.id),
                is_reauthenticating=self.reauthenticating_account_id == account.id,
                actions=AccountRowActions(
                    switch=lambda current=account: self.switch_account(current),
                    refresh=lambda current=account: self.refresh_account(current),
                    reauthenticate=lambda current=account: self.reauthenticate(current),
                    rename=lambda current=account: self.prompt_nickname(current),
                    copy_email=lambda current=account: self.copy_email(current),
                    open_folder=lambda current=account: self.open_folder(current),
                    remove=lambda current=account: self.remove_account(current),
                ),
            )
            row.pack(fill="x")

        self.cards_frame.update_idletasks()
        self.canvas.configure(scrollregion=self.canvas.bbox("all"))

    def _build_card_row_specs(self, accounts: list[StoredAccount]) -> list[tuple[list[StoredAccount], bool]]:
        columns = self._cards_column_count()
        pending: list[StoredAccount] = []
        rows: list[tuple[list[StoredAccount], bool]] = []

        for account in accounts:
            if columns > 1 and self.selected_account_id == account.id:
                if pending:
                    rows.append((pending, False))
                    pending = []
                rows.append(([account], True))
                continue

            pending.append(account)
            if len(pending) == columns:
                rows.append((pending, False))
                pending = []

        if pending:
            rows.append((pending, False))
        return rows

    def _render_card_rows_chunk(
        self,
        row_specs: list[tuple[list[StoredAccount], bool]],
        start: int,
        token: int,
    ) -> None:
        if token != self._cards_render_token:
            return

        end = min(start + self.CARD_RENDER_BATCH_ROWS, len(row_specs))
        for accounts, span_all in row_specs[start:end]:
            self._render_card_row(accounts, span_all)

        if end >= len(row_specs):
            self._cards_render_job = None
            self.canvas.configure(scrollregion=self.canvas.bbox("all"))
            return

        self._cards_render_job = self.root.after(
            1,
            lambda next_start=end, next_token=token: self._render_card_rows_chunk(
                row_specs,
                next_start,
                next_token,
            )
        )

    def _cancel_cards_render_job(self) -> None:
        if self._cards_render_job is None:
            return
        try:
            self.root.after_cancel(self._cards_render_job)
        except tk.TclError:
            pass
        self._cards_render_job = None

    def _render_card_row(self, accounts: list[StoredAccount], span_all: bool) -> None:
        row = tk.Frame(self.cards_frame, bg=self.palette["shell"])
        row.pack(fill="x", pady=(0, 8))

        if span_all:
            card = self._build_account_card(
                row,
                accounts[0],
                width_hint=self._card_width(self._cards_column_count()),
            )
            card.pack(fill="x")
            return

        row_gap = self._card_gap()
        row_count = len(accounts)
        for index, account in enumerate(accounts):
            span = self._cards_column_count() if row_count == 1 else 1
            card = self._build_account_card(
                row,
                account,
                width_hint=self._card_width(span),
            )
            card.pack(side="left", fill="both", expand=True)
            if index < row_count - 1:
                tk.Frame(row, bg=self.palette["shell"], width=row_gap).pack(side="left")

    def _render_empty_state(self, search_query: str) -> None:
        panel = tk.Frame(
            self.cards_frame,
            bg=self.palette["list"],
            padx=20,
            pady=36,
        )
        panel.pack(fill="x")

        title = "No Accounts" if not search_query else "No Matches"
        message = (
            "Add a Codex account to start tracking quota."
            if not self.accounts
            else "No accounts match your current search."
        )
        tk.Label(
            panel,
            text=title,
            bg=self.palette["list"],
            fg=self.palette["text"],
            font=self.fonts["headline"],
        ).pack()
        tk.Label(
            panel,
            text=message,
            bg=self.palette["list"],
            fg=self.palette["muted"],
            font=self.fonts["body_small"],
            wraplength=self._wrap_width(),
            justify="center",
        ).pack(pady=(6, 0))

    def _build_account_card(self, parent: tk.Widget, account: StoredAccount, width_hint: int) -> tk.Frame:
        state = self.runtime_states.get(account.id, AccountRuntimeState())
        is_selected = self.selected_account_id == account.id
        is_active = self._is_active_account(account)
        is_compact = width_hint <= 430
        card_bg = self.palette["selected"] if is_selected else self.palette["panel"]
        border = self.palette["accent_line"] if is_selected else self.palette["hairline"]
        text_width = max(150, width_hint - 156)

        card = tk.Frame(
            parent,
            bg=card_bg,
            highlightthickness=1,
            highlightbackground=border,
            padx=8,
            pady=8,
        )
        self._bind_click(card, lambda _: self._toggle_selection(account.id))

        header = tk.Frame(card, bg=card_bg)
        header.pack(fill="x")
        self._bind_click(header, lambda _: self._toggle_selection(account.id))

        title_wrap = tk.Frame(header, bg=card_bg)
        title_wrap.pack(side="left", fill="x", expand=True)
        self._bind_click(title_wrap, lambda _: self._toggle_selection(account.id))

        title_row = tk.Frame(title_wrap, bg=card_bg)
        title_row.pack(fill="x")
        self._bind_click(title_row, lambda _: self._toggle_selection(account.id))

        title = tk.Label(
            title_row,
            text=self._ellipsize(account.display_name, self.fonts["headline"], text_width),
            bg=card_bg,
            fg=self.palette["text"],
            font=self.fonts["headline"],
        )
        title.pack(side="left")
        self._bind_click(title, lambda _: self._toggle_selection(account.id))

        if is_active:
            active_chip = self._make_inline_chip(
                title_row,
                "Active",
                self.palette["accent_soft"],
                self.palette["accent"],
            )
            active_chip.pack(side="left", padx=(8, 0))
            self._bind_click(active_chip, lambda _: self._toggle_selection(account.id))

        if account.source is StoredAccountSource.AMBIENT:
            system_chip = self._make_inline_chip(
                title_row,
                "System",
                self.palette["panel_alt"],
                self.palette["muted"],
            )
            system_chip.pack(side="left", padx=(8, 0))
            self._bind_click(system_chip, lambda _: self._toggle_selection(account.id))

        meta_row = tk.Frame(title_wrap, bg=card_bg)
        meta_row.pack(fill="x", pady=(4, 0))
        self._bind_click(meta_row, lambda _: self._toggle_selection(account.id))

        meta = tk.Label(
            meta_row,
            text=self._ellipsize(account.email_hint or account.source.display_name, self.fonts["caption"], text_width),
            bg=card_bg,
            fg=self.palette["muted"],
            font=self.fonts["caption"],
        )
        meta.pack(side="left")
        self._bind_click(meta, lambda _: self._toggle_selection(account.id))

        right = tk.Frame(header, bg=card_bg)
        right.pack(side="right", padx=(8, 0))

        if state.snapshot is not None:
            self._make_inline_chip(
                right,
                state.snapshot.plan_display_name,
                self.palette["panel_alt"],
                self.palette["muted"],
            ).pack(anchor="e")

        status_row = tk.Frame(right, bg=card_bg)
        status_row.pack(anchor="e", pady=(4 if state.snapshot is not None else 0, 0))

        status_dot = tk.Canvas(status_row, width=7, height=7, bg=card_bg, highlightthickness=0)
        status_dot.pack(side="left", padx=(0, 6))
        status_dot.create_oval(0, 0, 7, 7, fill=self._status_color(state), outline="")

        tk.Label(
            status_row,
            text=self._status_value_text(state),
            bg=card_bg,
            fg=self.palette["text"],
            font=self.fonts["headline"],
        ).pack(side="left")

        if not is_active and self._can_switch_account(account):
            quick_actions = tk.Frame(right, bg=card_bg)
            quick_actions.pack(anchor="e", pady=(8, 0))
            self._make_button(
                quick_actions,
                "Switch",
                lambda: self.switch_account(account),
                kind="surface_tiny",
                icon=self.icons["add"],
            ).pack(anchor="e")

        summary = tk.Frame(card, bg=card_bg)
        summary.pack(fill="x", pady=(8, 0))
        self._bind_click(summary, lambda _: self._toggle_selection(account.id))

        if state.snapshot is not None and state.snapshot.has_quota_windows:
            summary_panel = tk.Frame(
                summary,
                bg=self.palette["panel_alt"],
                highlightthickness=1,
                highlightbackground=self.palette["hairline"],
                padx=9,
                pady=8,
            )
            summary_panel.pack(fill="x")
            windows = [candidate for candidate in (state.snapshot.primary_window, state.snapshot.secondary_window) if candidate]
            for index, window in enumerate(windows):
                strip = self._build_window_strip(summary_panel, window, width_hint)
                strip.pack(fill="x")
                self._bind_click(strip, lambda _, account_id=account.id: self._toggle_selection(account_id))
                if index < len(windows) - 1:
                    divider = tk.Frame(summary_panel, bg=self.palette["hairline"], height=1)
                    divider.pack(fill="x", pady=7)
        else:
            summary_panel = tk.Frame(
                summary,
                bg=self.palette["panel_alt"],
                highlightthickness=1,
                highlightbackground=self.palette["hairline"],
                padx=9,
                pady=8,
            )
            summary_panel.pack(fill="x")
            message = tk.Label(
                summary_panel,
                text=self._inline_message(state),
                bg=self.palette["panel_alt"],
                fg=self._status_color(state),
                font=self.fonts["body_small"],
                justify="left",
                wraplength=self._card_wrap_width(width_hint),
            )
            message.pack(anchor="w")
            self._bind_click(message, lambda _: self._toggle_selection(account.id))

        if not is_selected:
            return card

        divider = tk.Frame(card, bg=self.palette["hairline"], height=1)
        divider.pack(fill="x", pady=9)

        actions = tk.Frame(card, bg=card_bg)
        actions.pack(fill="x")

        button_specs: list[tuple[str, Callable[[], None], str, str | None]] = [
            ("Refresh", lambda: self.refresh_account(account), "surface_small", self.icons["refresh"]),
        ]
        if is_active:
            button_specs.append(("Active", lambda: None, "surface_small", self.icons["spark"]))
        elif self._can_switch_account(account):
            button_specs.append(("Switch", lambda: self.switch_account(account), "surface_small", self.icons["add"]))
        button_specs.append(("Reauth", lambda: self.reauthenticate(account), "surface_small", self.icons["spark"]))
        button_specs.append(("Folder", lambda: self.open_folder(account), "surface_small", self.icons["folder"]))
        if account.source.owns_files:
            button_specs.append(("Remove", lambda: self.remove_account(account), "danger_small", self.icons["trash"]))

        self._render_action_buttons(actions, button_specs, width_hint)

        if not account.source.owns_files:
            tk.Label(
                actions,
                text="System account",
                bg=card_bg,
                fg=self.palette["muted"],
                font=self.fonts["body_small"],
            ).pack(anchor="w", pady=(8, 0))

        if state.snapshot is not None:
            actions_meta = tk.Frame(actions, bg=card_bg)
            actions_meta.pack(fill="x", pady=(8, 0))
            tk.Label(
                actions_meta,
                text=state.snapshot.updated_at.astimezone().strftime("Updated %H:%M"),
                bg=card_bg,
                fg=self.palette["muted"],
                font=self.fonts["caption"],
            ).pack(anchor="e")

        label_row = tk.Frame(card, bg=card_bg)
        label_row.pack(fill="x", pady=(9, 0))

        draft_var = tk.StringVar(value=self.nickname_drafts.get(account.id, account.nickname or ""))

        def sync_draft(*_: Any) -> None:
            self.nickname_drafts[account.id] = draft_var.get()

        draft_var.trace_add("write", sync_draft)

        label_shell = tk.Frame(
            label_row,
            bg=self.palette["panel"],
            highlightthickness=1,
            highlightbackground=self.palette["hairline"],
            padx=8,
            pady=5,
        )
        if is_compact:
            label_shell.pack(fill="x")
        else:
            label_shell.pack(side="left", fill="x", expand=True)

        label_entry = tk.Entry(
            label_shell,
            textvariable=draft_var,
            relief="flat",
            bg=self.palette["panel"],
            fg=self.palette["text"],
            insertbackground=self.palette["text"],
            font=self.fonts["body_small"],
        )
        label_entry.pack(fill="x")

        save_button = self._make_button(
            label_row,
            "Save",
            lambda: self.update_nickname(account.id),
            kind="surface_small",
            icon=self.icons["save"],
        )
        if is_compact:
            save_button.pack(anchor="e", pady=(8, 0))
        else:
            save_button.pack(side="left", padx=(8, 0))

        footer = tk.Frame(card, bg=card_bg)
        footer.pack(fill="x", pady=(9, 0))

        tk.Label(
            footer,
            text=self._ellipsize(self._short_path(account.codex_home_path), self.fonts["mono"], self._card_wrap_width(width_hint)),
            bg=card_bg,
            fg=self.palette["muted"],
            font=self.fonts["mono"],
        ).pack(anchor="w")

        if state.snapshot is not None and state.snapshot.next_reset_at is not None:
            tk.Label(
                footer,
                text=f"Next reset {state.snapshot.next_reset_at.astimezone().strftime('%b %d %H:%M')}",
                bg=card_bg,
                fg=self.palette["muted"],
                font=self.fonts["caption"],
            ).pack(anchor="w", pady=(4, 0))

        return card

    def _render_action_buttons(
        self,
        parent: tk.Widget,
        button_specs: list[tuple[str, Callable[[], None], str, str | None]],
        width_hint: int,
    ) -> None:
        max_per_row = 2 if width_hint < 370 else 3 if width_hint < 560 else 5
        for start in range(0, len(button_specs), max_per_row):
            row = tk.Frame(parent, bg=parent.cget("bg"))
            row.pack(fill="x", pady=(0, 6 if start + max_per_row < len(button_specs) else 0))
            current = button_specs[start:start + max_per_row]
            for index, (text, command, kind, icon) in enumerate(current):
                button = self._make_button(row, text, command, kind, icon=icon)
                button.pack(side="left")
                if index < len(current) - 1:
                    tk.Frame(row, bg=parent.cget("bg"), width=6).pack(side="left")

    def _build_window_strip(self, parent: tk.Widget, window: Any, width_hint: int) -> tk.Frame:
        strip = tk.Frame(parent, bg=self.palette["panel_alt"])

        header = tk.Frame(strip, bg=self.palette["panel_alt"])
        header.pack(fill="x")
        tk.Label(
            header,
            text=window.short_label.upper(),
            bg=self.palette["panel_alt"],
            fg=self._quota_color(window.remaining_percent),
            font=self.fonts["label"],
        ).pack(side="left")
        tk.Label(
            header,
            text=window.display_name,
            bg=self.palette["panel_alt"],
            fg=self.palette["muted"],
            font=self.fonts["caption"],
        ).pack(side="left", padx=(8, 0))
        tk.Label(
            header,
            text=f"{window.remaining_percent:.0f}%",
            bg=self.palette["panel_alt"],
            fg=self.palette["text"],
            font=self.fonts["headline"],
        ).pack(side="right")

        bar = tk.Canvas(strip, height=5, bg=self.palette["panel_alt"], highlightthickness=0, bd=0)
        bar.pack(fill="x", pady=(8, 6))
        bar_width = self._card_progress_width(width_hint)
        bar.create_rectangle(0, 0, bar_width, 5, fill=self.palette["track"], outline="")
        fill_width = max(0, min(bar_width, int(bar_width * (window.remaining_percent / 100.0))))
        bar.create_rectangle(0, 0, fill_width, 5, fill=self._quota_color(window.remaining_percent), outline="")

        footer = tk.Frame(strip, bg=self.palette["panel_alt"])
        footer.pack(fill="x")
        tk.Label(
            footer,
            text=f"Used {window.used_percent:.0f}%",
            bg=self.palette["panel_alt"],
            fg=self.palette["muted"],
            font=self.fonts["caption"],
        ).pack(side="left")
        tk.Label(
            footer,
            text=window.compact_reset_at_display or "Reset unknown",
            bg=self.palette["panel_alt"],
            fg=self.palette["muted"],
            font=self.fonts["caption"],
        ).pack(side="right")
        return strip

    def _build_window_tile(self, parent: tk.Widget, card_bg: str, window: Any) -> tk.Frame:
        tile = tk.Frame(
            parent,
            bg=self.palette["panel_alt"],
            highlightthickness=1,
            highlightbackground=self.palette["hairline"],
            padx=10,
            pady=8,
        )

        header = tk.Frame(tile, bg=self.palette["panel_alt"])
        header.pack(fill="x")
        tk.Label(
            header,
            text=window.short_label.upper(),
            bg=self.palette["panel_alt"],
            fg=self._quota_color(window.remaining_percent),
            font=self.fonts["label"],
        ).pack(side="left")
        tk.Label(
            header,
            text=window.display_name,
            bg=self.palette["panel_alt"],
            fg=self.palette["muted"],
            font=self.fonts["caption"],
        ).pack(side="left", padx=(8, 0))
        tk.Label(
            header,
            text=f"{window.remaining_percent:.0f}%",
            bg=self.palette["panel_alt"],
            fg=self.palette["text"],
            font=self.fonts["headline"],
        ).pack(side="right")

        bar = tk.Canvas(tile, height=6, bg=self.palette["panel_alt"], highlightthickness=0, bd=0)
        bar.pack(fill="x", pady=(8, 7))
        bar_width = self._progress_width()
        bar.create_rectangle(0, 0, bar_width, 6, fill=self.palette["track"], outline="")
        fill_width = max(0, min(bar_width, int(bar_width * (window.remaining_percent / 100.0))))
        bar.create_rectangle(0, 0, fill_width, 6, fill=self._quota_color(window.remaining_percent), outline="")

        footer = tk.Frame(tile, bg=self.palette["panel_alt"])
        footer.pack(fill="x")
        tk.Label(
            footer,
            text=f"Used {window.used_percent:.0f}%",
            bg=self.palette["panel_alt"],
            fg=self.palette["muted"],
            font=self.fonts["caption"],
        ).pack(side="left")
        reset_text = window.compact_reset_at_display or "Reset unknown"
        tk.Label(
            footer,
            text=reset_text,
            bg=self.palette["panel_alt"],
            fg=self.palette["muted"],
            font=self.fonts["caption"],
        ).pack(side="right")
        return tile

    def _toggle_selection(self, account_id: UUID) -> None:
        self.selected_account_id = None if self.selected_account_id == account_id else account_id
        self._render()

    def _header_status_text(self, presentation: PresentationState) -> str:
        if self.status_message:
            return self.status_message
        account_label = "account" if presentation.account_count == 1 else "accounts"
        if presentation.low_quota_count > 0:
            return f"{presentation.account_count} {account_label}, {presentation.low_quota_count} critical"
        return f"{presentation.account_count} {account_label}"

    def _status_text(self, state: AccountRuntimeState) -> str:
        if state.is_loading:
            return "Syncing"
        if state.error_message:
            return "Attention"
        if state.snapshot is None:
            return "Pending"
        if state.snapshot.has_usable_quota_now:
            return "Available"
        if state.snapshot.is_quota_blocked:
            return "Blocked"
        return "Limited"

    def _status_value_text(self, state: AccountRuntimeState) -> str:
        if state.snapshot is not None:
            return f"{state.snapshot.lowest_remaining_percent:.0f}%"
        if state.is_loading:
            return "..."
        return "--"

    def _inline_message(self, state: AccountRuntimeState) -> str:
        if state.is_loading:
            return "Refreshing live quota data..."
        if state.error_message:
            return state.error_message
        if state.snapshot is None:
            return "Waiting for data."
        if state.snapshot.is_quota_blocked:
            return "Quota reached."
        return "No quota data."

    def _status_color(self, state: AccountRuntimeState) -> str:
        if state.error_message:
            return self.palette["warning"]
        if state.is_loading:
            return self.palette["neutral"]
        if state.snapshot is None:
            return self.palette["neutral"]
        return self._quota_color(state.snapshot.lowest_remaining_percent)

    def _quota_color(self, remaining: float) -> str:
        if remaining <= 10:
            return self.palette["danger"]
        if remaining <= 20:
            return self.palette["warning"]
        return self.palette["success"]

    def _make_button(
        self,
        parent: tk.Widget,
        text: str,
        command: Callable[[], None],
        kind: str,
        icon: str | None = None,
    ) -> RoundedButton:
        button = RoundedButton(
            parent,
            text=text,
            command=command,
            theme=self._button_theme(kind),
            font=self._button_font(kind),
            icon=icon,
            icon_font=self.fonts["icon_small"],
            radius=self._button_radius(kind),
            pad_x=self._button_pad(kind)[0],
            pad_y=self._button_pad(kind)[1],
        )
        return button

    def _button_theme(self, kind: str) -> RoundedButtonTheme:
        if kind == "accent":
            return RoundedButtonTheme(
                bg=self.palette["accent_soft"],
                fg=self.palette["accent"],
                hover="#184247",
                border=self.palette["accent_line"],
                disabled_bg=self.palette["panel_alt"],
                disabled_fg=self.palette["neutral"],
            )
        if kind == "danger_small":
            return RoundedButtonTheme(
                bg="#351d21",
                fg=self.palette["danger"],
                hover="#46262c",
                border="#5a3338",
                disabled_bg=self.palette["panel_alt"],
                disabled_fg=self.palette["neutral"],
            )
        return RoundedButtonTheme(
            bg=self.palette["panel_alt"],
            fg=self.palette["text"],
            hover=self.palette["control_hover"],
            border=self.palette["hairline"],
            disabled_bg=self.palette["panel_alt"],
            disabled_fg=self.palette["neutral"],
        )

    def _button_font(self, kind: str) -> tuple[str, int] | tuple[str, int, str]:
        if kind in {"surface_small", "danger_small", "surface_tiny"}:
            return self.fonts["button_small"]
        return self.fonts["button"]

    def _button_radius(self, kind: str) -> int:
        if kind == "surface_tiny":
            return 9
        if kind in {"surface_small", "danger_small"}:
            return 10
        return 11

    def _button_pad(self, kind: str) -> tuple[int, int]:
        if kind == "surface_tiny":
            return 8, 5
        if kind in {"surface_small", "danger_small"}:
            return 10, 6
        return 12, 7

    def _make_inline_chip(self, parent: tk.Widget, text: str, bg: str, fg: str) -> tk.Frame:
        chip = tk.Frame(parent, bg=bg, padx=7, pady=3)
        label = tk.Label(chip, text=text, bg=bg, fg=fg, font=self.fonts["label"])
        label.pack()
        return chip

    def _update_tray(self, presentation: PresentationState) -> None:
        if self.tray_icon is None:
            return

        state = presentation.menu_bar_quota_state
        self.tray_icon.icon = self._create_icon_image(state, 64)
        self.tray_icon.title = f"{APP_DISPLAY_NAME} - {self._header_status_text(presentation)}"
        try:
            self.tray_icon.update_menu()
        except Exception:
            pass

    def _create_icon_image(self, state: str, size: int) -> Image.Image:
        return build_codex_vitals_icon(size)

    def _short_path(self, path: str) -> str:
        if len(path) <= 34:
            return path
        return f"...{path[-31:]}"

    def _header_wrap_width(self) -> int:
        return max(220, self.shell.winfo_width() - 24)

    def _cards_available_width(self) -> int:
        return max(320, self.canvas.winfo_width() - 4)

    def _card_gap(self) -> int:
        return 10

    def _cards_column_count(self) -> int:
        return 2 if self._cards_available_width() >= 860 else 1

    def _card_width(self, span: int = 1) -> int:
        columns = self._cards_column_count()
        available = self._cards_available_width()
        if span >= columns:
            return available
        total_gap = self._card_gap() * (columns - 1)
        column_width = max(240, int((available - total_gap) / columns))
        return column_width

    def _card_wrap_width(self, width_hint: int) -> int:
        return max(180, width_hint - 58)

    def _card_progress_width(self, width_hint: int) -> int:
        return max(132, width_hint - 74)

    def _wrap_width(self) -> int:
        return self._card_wrap_width(self._cards_available_width())

    def _progress_width(self) -> int:
        return self._card_progress_width(self._cards_available_width())

    def _is_compact_card_layout(self) -> bool:
        return self.canvas.winfo_width() <= 420

    def _ellipsize(
        self,
        text: str,
        font_spec: tuple[str, int] | tuple[str, int, str],
        max_width: int,
    ) -> str:
        if max_width <= 0:
            return text

        font_key = tuple(font_spec)
        cache_key = (text, font_key, max_width)
        cached = self._ellipsize_cache.get(cache_key)
        if cached is not None:
            return cached

        font = self._font_object(font_spec)
        if font.measure(text) <= max_width:
            result = text
        else:
            ellipsis = "..."
            truncated = text
            while truncated and font.measure(truncated + ellipsis) > max_width:
                truncated = truncated[:-1]
            result = (truncated or text[:1]) + ellipsis

        if len(self._ellipsize_cache) >= self.ELLIPSIS_CACHE_MAX:
            self._ellipsize_cache.clear()
        self._ellipsize_cache[cache_key] = result
        return result

    def _font_object(
        self,
        font_spec: tuple[str, int] | tuple[str, int, str],
    ) -> tkfont.Font:
        key = tuple(font_spec)
        cached = self._font_object_cache.get(key)
        if cached is not None:
            return cached

        font = tkfont.Font(font=font_spec)
        self._font_object_cache[key] = font
        return font

    def _on_root_configure(self, event: tk.Event[Any]) -> None:
        if event.widget is not self.root:
            return

        if event.width == self._last_render_width:
            return

        self._last_render_width = event.width
        self._ellipsize_cache.clear()
        if self._resize_job is not None:
            self.root.after_cancel(self._resize_job)
        self._resize_job = self.root.after(90, self._render_after_resize)

    def _render_after_resize(self) -> None:
        self._resize_job = None
        self._render()

    def _apply_dark_title_bar(self) -> None:
        if os.name != "nt":
            return

        try:
            hwnd = ctypes.windll.user32.GetParent(self.root.winfo_id())
            if not hwnd:
                hwnd = self.root.winfo_id()
            value = ctypes.c_int(1 if self.is_dark_mode else 0)
            for attribute in (20, 19):
                ctypes.windll.dwmapi.DwmSetWindowAttribute(
                    hwnd,
                    attribute,
                    ctypes.byref(value),
                    ctypes.sizeof(value),
                )
            corner_preference = ctypes.c_int(2)
            ctypes.windll.dwmapi.DwmSetWindowAttribute(
                hwnd,
                33,
                ctypes.byref(corner_preference),
                ctypes.sizeof(corner_preference),
            )
        except Exception:
            pass

    def _on_cards_configure(self, event: tk.Event[tk.Widget]) -> None:
        self.canvas.configure(scrollregion=self.canvas.bbox("all"))

    def _on_canvas_configure(self, event: tk.Event[tk.Widget]) -> None:
        self.canvas.itemconfigure(self.cards_window, width=event.width)

    def _on_settings_content_configure(self, _: tk.Event[tk.Widget]) -> None:
        self.settings_canvas.configure(scrollregion=self.settings_canvas.bbox("all"))

    def _on_settings_canvas_configure(self, event: tk.Event[tk.Widget]) -> None:
        content_width = min(540, max(320, event.width - 32))
        content_x = max(16, int((event.width - content_width) / 2))
        self.settings_canvas.coords(self.settings_window, content_x, 0)
        self.settings_canvas.itemconfigure(self.settings_window, width=content_width)
        self.settings_status_label.configure(wraplength=max(280, content_width - 12))

    def _on_mousewheel(self, event: tk.Event[tk.Widget]) -> None:
        if event.delta:
            target = self.settings_canvas if self.settings_visible else self.canvas
            target.yview_scroll(int(-event.delta / 120), "units")

    def _bind_click(self, widget: tk.Widget, callback: Callable[[tk.Event[Any]], None]) -> None:
        widget.bind("<Button-1>", callback)

    def _on_search_change(self) -> None:
        self._mark_search_dirty()
        if self._search_render_job is not None:
            try:
                self.root.after_cancel(self._search_render_job)
            except tk.TclError:
                pass
        self._search_render_job = self.root.after(self.SEARCH_RENDER_MS, self._flush_search_render)

    def _flush_search_render(self) -> None:
        self._search_render_job = None
        self._render()

    def _invalidate_presentation_cache(self) -> None:
        self._presentation_cache_key = None
        self._presentation_cache = None

    def _mark_accounts_dirty(self) -> None:
        self._accounts_revision += 1
        self._invalidate_presentation_cache()

    def _mark_runtime_dirty(self) -> None:
        self._runtime_revision += 1
        self._invalidate_presentation_cache()

    def _mark_search_dirty(self) -> None:
        self._search_revision += 1
        self._invalidate_presentation_cache()

    def _build_presentation_state(self) -> PresentationState:
        cache_key = (self._accounts_revision, self._runtime_revision, self._search_revision)
        if self._presentation_cache_key == cache_key and self._presentation_cache is not None:
            return self._presentation_cache

        query = self.search_var.get().strip().casefold()
        filtered: list[tuple[tuple[int, int, float, float, str], StoredAccount]] = []
        low_quota_count = 0
        usable_quota_count = 0
        exhausted_count = 0

        for account in self.accounts:
            snapshot = self.runtime_states.get(account.id, AccountRuntimeState()).snapshot
            if snapshot is not None:
                if snapshot.lowest_remaining_percent <= 20:
                    low_quota_count += 1
                if snapshot.has_usable_quota_now:
                    usable_quota_count += 1
                else:
                    exhausted_count += 1

            if query and not self._matches_search_query(account, query):
                continue

            filtered.append((account_sort_key(account, snapshot), account))

        filtered.sort(key=lambda item: item[0])
        presentation = PresentationState(
            search_query=query,
            filtered_accounts=[account for _, account in filtered],
            account_count=len(self.accounts),
            low_quota_count=low_quota_count,
            usable_quota_count=usable_quota_count,
            exhausted_count=exhausted_count,
        )
        self._presentation_cache_key = cache_key
        self._presentation_cache = presentation
        return presentation

    def _matches_search_query(self, account: StoredAccount, query: str) -> bool:
        return any(
            query in candidate.casefold()
            for candidate in (
                account.display_name,
                account.email_hint or "",
                account.auth_subject or "",
                account.provider_account_id or "",
                account.codex_home_path,
            )
        )


def main(argv: list[str] | None = None) -> None:
    arguments = list(sys.argv[1:] if argv is None else argv)
    start_hidden = any(argument.lower() in {"--hidden", "/hidden"} for argument in arguments)
    app = CodexVitalsWindowsApp(start_hidden=start_hidden)
    app.run()
