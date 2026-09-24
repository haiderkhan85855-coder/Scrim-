import type {
  AnchorHTMLAttributes,
  ButtonHTMLAttributes,
  ReactNode,
} from "react";

type ButtonVariant = "primary" | "secondary";

type SharedProps = {
  children: ReactNode;
  variant?: ButtonVariant;
  className?: string;
};

type ButtonAsButton = SharedProps &
  ButtonHTMLAttributes<HTMLButtonElement> & {
    href?: undefined;
  };

type ButtonAsLink = SharedProps &
  AnchorHTMLAttributes<HTMLAnchorElement> & {
    href: string;
  };

type ButtonProps = ButtonAsButton | ButtonAsLink;

const variantClasses: Record<ButtonVariant, string> = {
  primary:
    "bg-accent text-background hover:bg-accent-hover hover:-translate-y-0.5 focus-visible:outline-accent active:translate-y-0",
  secondary:
    "border border-border-strong bg-transparent text-foreground hover:border-foreground/45 hover:bg-foreground/[0.03] hover:-translate-y-0.5 focus-visible:outline-foreground/40 active:translate-y-0",
}

/**
 * Sharp, premium CTA control. Prefer links via `href` for navigation actions.
 */
export function Button({
  children,
  variant = "primary",
  className = "",
  ...props
}: ButtonProps) {
  const classes = [
    "inline-flex items-center justify-center gap-2",
    "min-h-12 px-6",
    "font-[family-name:var(--font-body)] text-[0.625rem] font-medium uppercase tracking-[0.18em]",
    "rounded-[2px] transition-[background-color,border-color,color,transform] duration-300 ease-[var(--ease-out-expo)]",
    "focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2",
    "disabled:pointer-events-none disabled:opacity-40",
    variantClasses[variant],
    className,
  ].join(" ");

  if ("href" in props && props.href) {
    const { href, ...linkProps } = props;
    return (
      <a href={href} className={classes} {...linkProps}>
        {children}
      </a>
    );
  }

  const buttonProps = props as ButtonAsButton;
  const { type = "button", ...rest } = buttonProps;

  return (
    <button type={type} className={classes} {...rest}>
      {children}
    </button>
  );
}
