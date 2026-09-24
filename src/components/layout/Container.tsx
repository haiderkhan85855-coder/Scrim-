import type { ElementType, ReactNode } from "react";

type ContainerProps = {
  children: ReactNode;
  className?: string;
  as?: ElementType;
};

/**
 * Shared horizontal rhythm for the site.
 * Full-width friendly with a controlled max width and generous padding.
 */
export function Container({
  children,
  className = "",
  as: Tag = "div",
}: ContainerProps) {
  return (
    <Tag
      className={`mx-auto w-full max-w-[var(--container-max)] px-[var(--container-pad)] ${className}`}
    >
      {children}
    </Tag>
  );
}
