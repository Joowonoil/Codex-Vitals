from __future__ import annotations

import unittest
from datetime import datetime, timedelta, timezone
from uuid import uuid4

from codexvitals_windows.codex_api import AuthBackedIdentity
from codexvitals_windows.models import AccountUsageSnapshot, StoredAccount, StoredAccountSource, UsageWindowSnapshot
from codexvitals_windows.presentation_logic import (
    account_sort_key,
    compact_reset_countdown,
    is_active_account,
    quota_window_label,
    quota_window_slots,
)


def make_account(
    *,
    email: str,
    auth_subject: str | None,
    provider_account_id: str | None,
    path_suffix: str,
) -> StoredAccount:
    now = datetime(2026, 4, 19, tzinfo=timezone.utc)
    return StoredAccount(
        id=uuid4(),
        nickname=None,
        email_hint=email,
        auth_subject=auth_subject,
        provider_account_id=provider_account_id,
        codex_home_path=f"C:/accounts/{path_suffix}",
        source=StoredAccountSource.MANAGED_BY_APP,
        created_at=now,
        updated_at=now,
        last_authenticated_at=now,
    )


def make_snapshot(*, remaining: float, reset_hour: int, blocked: bool = False) -> AccountUsageSnapshot:
    now = datetime(2026, 4, 19, reset_hour, tzinfo=timezone.utc)
    return AccountUsageSnapshot(
        email="user@example.com",
        provider_account_id="provider-1",
        plan="team",
        allowed=False if blocked else True,
        limit_reached=True if blocked else False,
        primary_window=UsageWindowSnapshot(
            used_percent=100.0 - remaining,
            reset_at=now,
            limit_window_seconds=18_000,
        ),
        secondary_window=None,
        credits=None,
        updated_at=now,
    )


class PresentationLogicTests(unittest.TestCase):
    def test_is_active_account_ignores_shared_provider_id(self) -> None:
        identity = AuthBackedIdentity(
            email="bruno@example.com",
            auth_subject="auth0|bruno",
            plan="team",
            provider_account_id="shared-provider",
        )
        bruno = make_account(
            email="bruno@example.com",
            auth_subject="auth0|bruno",
            provider_account_id="shared-provider",
            path_suffix="bruno",
        )
        charles = make_account(
            email="charles@example.com",
            auth_subject="auth0|charles",
            provider_account_id="shared-provider",
            path_suffix="charles",
        )

        self.assertTrue(is_active_account(bruno, identity))
        self.assertFalse(is_active_account(charles, identity))

    def test_account_sort_key_prioritizes_usable_quota(self) -> None:
        usable_account = make_account(
            email="usable@example.com",
            auth_subject="auth0|usable",
            provider_account_id="provider-1",
            path_suffix="usable",
        )
        blocked_account = make_account(
            email="blocked@example.com",
            auth_subject="auth0|blocked",
            provider_account_id="provider-2",
            path_suffix="blocked",
        )
        snapshots = {
            usable_account.id: make_snapshot(remaining=1.0, reset_hour=18, blocked=False),
            blocked_account.id: make_snapshot(remaining=0.0, reset_hour=16, blocked=True),
        }

        ordered = sorted(
            [blocked_account, usable_account],
            key=lambda account: account_sort_key(account, snapshots.get(account.id)),
        )

        self.assertEqual([account.display_name for account in ordered], ["usable@example.com", "blocked@example.com"])

    def test_account_sort_key_uses_reset_order_for_blocked_accounts(self) -> None:
        earlier = make_account(
            email="earlier@example.com",
            auth_subject="auth0|earlier",
            provider_account_id="provider-1",
            path_suffix="earlier",
        )
        later = make_account(
            email="later@example.com",
            auth_subject="auth0|later",
            provider_account_id="provider-2",
            path_suffix="later",
        )
        snapshots = {
            earlier.id: make_snapshot(remaining=0.0, reset_hour=16, blocked=True),
            later.id: make_snapshot(remaining=0.0, reset_hour=20, blocked=True),
        }

        ordered = sorted(
            [later, earlier],
            key=lambda account: account_sort_key(account, snapshots.get(account.id)),
        )

        self.assertEqual([account.display_name for account in ordered], ["earlier@example.com", "later@example.com"])

    def test_quota_window_slots_keep_weekly_only_data_in_weekly_column(self) -> None:
        now = datetime(2026, 7, 17, 12, tzinfo=timezone.utc)
        weekly = UsageWindowSnapshot(
            used_percent=42.0,
            reset_at=now + timedelta(days=3),
            limit_window_seconds=604_800,
        )
        snapshot = AccountUsageSnapshot(
            email="weekly@example.com",
            provider_account_id="provider-weekly",
            plan="pro",
            allowed=True,
            limit_reached=False,
            primary_window=weekly,
            secondary_window=None,
            credits=None,
            updated_at=now,
        )

        slots = quota_window_slots(snapshot)

        self.assertNotIn("5h", slots)
        self.assertIs(slots["1w"], weekly)
        self.assertEqual(quota_window_label(weekly), "1w")

    def test_compact_reset_countdown_formats_session_and_weekly_resets(self) -> None:
        now = datetime(2026, 7, 17, 12, tzinfo=timezone.utc)

        self.assertEqual(compact_reset_countdown(now + timedelta(hours=3, minutes=7), now), "03:07")
        self.assertEqual(compact_reset_countdown(now + timedelta(days=3, hours=4), now), "3d 4h")


if __name__ == "__main__":
    unittest.main()
