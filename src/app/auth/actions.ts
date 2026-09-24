"use server";

import { headers } from "next/headers";
import { redirect } from "next/navigation";
import type { AuthError } from "@supabase/supabase-js";

import {
  getCurrentAdminAccess,
  hasRequiredAdminRole,
} from "@/lib/auth/admin";
import { createClient } from "@/lib/supabase/server";

export type AuthActionState = {
  error?: string;
  message?: string;
};

const emailPattern = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

function readField(formData: FormData, field: string, trim = true) {
  const value = formData.get(field);
  return typeof value === "string" ? (trim ? value.trim() : value) : "";
}

function safeNextPath(value: string) {
  return value.startsWith("/") &&
    !value.startsWith("//") &&
    !value.includes("\\")
    ? value
    : null;
}

function reportAuthError(operation: "login" | "signup", error: AuthError) {
  if (process.env.NODE_ENV !== "production") {
    console.error(
      `[Supabase Auth: ${operation}] ${JSON.stringify({
        code: error.code ?? null,
        message: error.message,
        name: error.name,
        status: error.status ?? null,
      })}`,
    );
  }
}

function authErrorMessage(error: AuthError) {
  const normalized = error.message.toLowerCase();

  if (normalized.includes("invalid login credentials")) {
    return "The email or password is incorrect.";
  }

  if (normalized.includes("email not confirmed")) {
    return "Confirm your email address before signing in.";
  }

  if (normalized.includes("user already registered")) {
    return "An account already exists for this email. Try signing in instead.";
  }

  if (error.code === "email_address_invalid") {
    return "Enter an email address that can receive confirmation messages.";
  }

  if (error.code === "email_address_not_authorized") {
    return "This Supabase project cannot send confirmation email to that address yet.";
  }

  if (error.code === "signup_disabled") {
    return "New account registration is currently unavailable.";
  }

  if (normalized.includes("rate limit")) {
    return "Too many attempts. Wait a moment, then try again.";
  }

  if (normalized.includes("password")) {
    return error.message;
  }

  if (process.env.NODE_ENV !== "production") {
    return `${error.message}${error.code ? ` (${error.code})` : ""}`;
  }

  return "We could not complete that request. Please try again.";
}

export async function login(
  _previousState: AuthActionState,
  formData: FormData,
): Promise<AuthActionState> {
  const email = readField(formData, "email");
  const password = readField(formData, "password", false);
  const nextPath = safeNextPath(readField(formData, "next"));

  if (!email || !password) {
    return { error: "Enter both your email and password." };
  }

  if (!emailPattern.test(email)) {
    return { error: "Enter a valid email address." };
  }

  const supabase = await createClient();
  const { error } = await supabase.auth.signInWithPassword({ email, password });

  if (error) {
    reportAuthError("login", error);
    return { error: authErrorMessage(error) };
  }

  const adminAccess = await getCurrentAdminAccess();

  if (hasRequiredAdminRole(adminAccess)) {
    redirect(nextPath ?? "/admin");
  }

  redirect(nextPath ?? "/?auth=welcome-back");
}

export async function register(
  _previousState: AuthActionState,
  formData: FormData,
): Promise<AuthActionState> {
  const email = readField(formData, "email");
  const password = readField(formData, "password", false);
  const confirmPassword = readField(formData, "confirmPassword", false);

  if (!email || !password || !confirmPassword) {
    return { error: "Complete all registration fields." };
  }

  if (!emailPattern.test(email)) {
    return { error: "Enter a valid email address." };
  }

  if (password !== confirmPassword) {
    return { error: "The passwords do not match." };
  }

  if (password.length < 8) {
    return { error: "Use a password with at least 8 characters." };
  }

  const requestHeaders = await headers();
  const origin = requestHeaders.get("origin");
  const emailRedirectTo = origin
    ? new URL("/auth/confirm", origin).toString()
    : undefined;
  const supabase = await createClient();
  const { data, error } = await supabase.auth.signUp({
    email,
    password,
    ...(emailRedirectTo
      ? {
          options: {
            emailRedirectTo,
          },
        }
      : {}),
  });

  if (error) {
    reportAuthError("signup", error);
    return { error: authErrorMessage(error) };
  }

  if (process.env.NODE_ENV !== "production") {
    console.info(
      `[Supabase Auth: signup result] ${JSON.stringify({
        redirectPath: emailRedirectTo ? "/auth/confirm" : "dashboard-default",
        hasSession: Boolean(data.session),
        hasUser: Boolean(data.user),
      })}`,
    );
  }

  if (data.session) {
    redirect("/welcome");
  }

  return {
    message:
      "Account created. Check your email and use the confirmation link to continue.",
  };
}

export async function logout() {
  const supabase = await createClient();
  await supabase.auth.signOut({ scope: "local" });
  redirect("/");
}
