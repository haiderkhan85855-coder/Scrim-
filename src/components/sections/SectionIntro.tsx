type SectionIntroProps = {
  eyebrow: string;
  title: string;
  description: string;
  revealAttribute?: string;
};

export function SectionIntro({
  eyebrow,
  title,
  description,
  revealAttribute,
}: SectionIntroProps) {
  const revealProps = revealAttribute
    ? { [revealAttribute]: "" }
    : undefined;

  return (
    <div className="min-w-0" {...revealProps}>
      <p className="section-eyebrow">
        <span aria-hidden className="h-3 w-1 bg-accent" />
        {eyebrow}
      </p>
      <h2 className="type-display mt-3 max-w-[15ch] text-[clamp(1.75rem,7.5vw,2.3rem)] uppercase leading-[0.92] tracking-[-0.045em] lg:mt-4 lg:text-[2.35rem]">
        {title}
      </h2>
      <p className="mt-3 max-w-sm text-sm leading-5 text-white/60 lg:mt-5 lg:leading-6">
        {description}
      </p>
    </div>
  );
}
