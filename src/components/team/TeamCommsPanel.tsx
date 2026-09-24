"use client";

import { useCallback, useEffect, useState } from "react";

import {
  getMyWhatsAppLinks,
  listMyNotifications,
  markNotificationRead,
  type MyWhatsAppLink,
  type TeamNotification,
} from "@/app/team/actions";

export default function TeamCommsPanel() {
  const [links, setLinks] = useState<MyWhatsAppLink[]>([]);
  const [notifications, setNotifications] = useState<TeamNotification[]>([]);
  const [loading, setLoading] = useState(true);

  const load = useCallback(async () => {
    const [linksResult, notificationsResult] = await Promise.all([
      getMyWhatsAppLinks(),
      listMyNotifications(),
    ]);
    setLinks(linksResult.data ?? []);
    setNotifications(notificationsResult.data ?? []);
    setLoading(false);
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const handleMarkRead = useCallback(async (id: string) => {
    setNotifications((current) =>
      current.map((notification) =>
        notification.id === id
          ? { ...notification, read_at: new Date().toISOString() }
          : notification,
      ),
    );
    await markNotificationRead(id);
  }, []);

  if (loading) return null;
  if (links.length === 0 && notifications.length === 0) return null;

  const unreadCount = notifications.filter((n) => !n.read_at).length;

  return (
    <section className="mb-6 space-y-4">
      {notifications.length > 0 ? (
        <div className="rounded-[2px] border border-border-strong bg-background-elevated/90 p-4 sm:p-5">
          <div className="flex items-center justify-between">
            <p className="text-[0.6rem] font-semibold uppercase tracking-[0.13em] text-foreground">
              Notifications
            </p>
            {unreadCount > 0 ? (
              <span className="rounded-[2px] bg-accent/20 px-2 py-1 text-[0.55rem] font-semibold uppercase tracking-[0.12em] text-accent">
                {unreadCount} new
              </span>
            ) : null}
          </div>
          <ul className="mt-3 space-y-2">
            {notifications.slice(0, 5).map((notification) => (
              <li
                key={notification.id}
                className={`rounded-[2px] border px-3 py-2 ${
                  notification.read_at
                    ? "border-border-strong opacity-70"
                    : "border-accent/30 bg-accent/5"
                }`}
              >
                <div className="flex items-start justify-between gap-2">
                  <div className="min-w-0">
                    <p className="text-sm font-medium">{notification.title}</p>
                    {notification.body ? (
                      <p className="mt-0.5 text-xs text-foreground-muted">
                        {notification.body}
                      </p>
                    ) : null}
                    <p className="mt-1 text-[0.55rem] uppercase tracking-[0.12em] text-foreground-subtle">
                      {notification.team_name}
                    </p>
                  </div>
                  {!notification.read_at ? (
                    <button
                      type="button"
                      onClick={() => handleMarkRead(notification.id)}
                      className="shrink-0 text-[0.55rem] font-semibold uppercase tracking-[0.12em] text-accent hover:underline"
                    >
                      Mark read
                    </button>
                  ) : null}
                </div>
                {notification.link ? (
                  <a
                    href={notification.link}
                    className="mt-1 inline-block text-xs text-sky-300 hover:underline"
                  >
                    Open →
                  </a>
                ) : null}
              </li>
            ))}
          </ul>
        </div>
      ) : null}

      {links.length > 0 ? (
        <div className="rounded-[2px] border border-emerald-400/30 bg-emerald-400/5 p-4 sm:p-5">
          <p className="text-[0.6rem] font-semibold uppercase tracking-[0.13em] text-emerald-300">
            WhatsApp tournament group
          </p>
          <ul className="mt-3 space-y-2">
            {links.map((link) => (
              <li key={link.tournament_id}>
                <a
                  href={link.whatsapp_group_link}
                  target="_blank"
                  rel="noreferrer"
                  className="flex flex-wrap items-center justify-between gap-2 rounded-[2px] border border-border-strong bg-background/60 px-3 py-2 transition-colors hover:border-emerald-400/40"
                >
                  <span className="text-sm">{link.tournament_name}</span>
                  <span className="text-[0.6rem] font-semibold uppercase tracking-[0.13em] text-emerald-300">
                    Join group ↗
                  </span>
                </a>
              </li>
            ))}
          </ul>
        </div>
      ) : null}
    </section>
  );
}
