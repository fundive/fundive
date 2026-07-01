import { siteConfig } from '../config/site'

// Brand logo — wraps the shop logo (fundive.config.ts `assets.logo`) with size
// presets so every surface that uses it picks a consistent height. FunDivers'
// image is the dive-mask-shaped mark (red/white/black on a transparent
// background), so it works on dark and light surfaces without modification.
//
// Sizes (height in px): xs 24, sm 36, md 56, lg 88, xl 128.
//
// The `beta` badge is off by default so a fork carries no permanent
// "BETA" mark; a surface that wants it opts in by passing `beta`.

const SIZE_CLASS: Record<'xs' | 'sm' | 'md' | 'lg' | 'xl', string> = {
  xs: 'h-6',
  sm: 'h-9',
  md: 'h-14',
  lg: 'h-22',
  xl: 'h-32',
}

export function Logo({
  size = 'md',
  className = '',
  beta = false,
}: {
  size?: 'xs' | 'sm' | 'md' | 'lg' | 'xl'
  className?: string
  beta?: boolean
}) {
  return (
    <span className="inline-flex items-start gap-1">
      <img
        src={siteConfig.assets.logo}
        alt={siteConfig.app.logoAlt}
        className={`${SIZE_CLASS[size]} w-auto ${className}`}
      />
      {beta && (
        <span className="bg-accent text-white rounded-full px-1.5 py-0.5 text-[10px] font-bold leading-none uppercase tracking-wide">
          Beta
        </span>
      )}
    </span>
  )
}
