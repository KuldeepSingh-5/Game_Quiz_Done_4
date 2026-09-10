// import { useEffect, useState } from 'react';
// import { Megaphone, Loader2, AlertCircle, X } from 'lucide-react';
// import type { AdSlotVariant, AdStatus } from '@/types/ads';
// import { adConfig } from '@/config/ads';
// import { useAdContext } from '@/context/AdContext';

// const AD_LOAD_MS = 1200;
// const SIMULATED_FAIL_RATE = 0.1;

// function useAdLifecycle(enabled: boolean): AdStatus {
//   const [status, setStatus] = useState<AdStatus>('idle');

//   useEffect(() => {
//     if (!enabled) {
//       setStatus('disabled');
//       return;
//     }
//     setStatus('loading');
//     const timer = setTimeout(() => {
//       const failed = Math.random() < SIMULATED_FAIL_RATE;
//       setStatus(failed ? 'error' : 'loaded');
//     }, AD_LOAD_MS);
//     return () => clearTimeout(timer);
//   }, [enabled]);

//   return status;
// }

// const VARIANT_SIZES: Record<AdSlotVariant, { container: string; label: string; sub: string }> = {
//   banner: {
//     container: 'h-16 sm:h-20',
//     label: 'Banner Ad',
//     sub: '728×90',
//   },
//   interstitial: {
//     container: 'h-48 sm:h-64',
//     label: 'Interstitial Ad',
//     sub: 'Full-screen',
//   },
//   rewarded: {
//     container: 'h-40 sm:h-52',
//     label: 'Rewarded Ad',
//     sub: 'Watch to earn',
//   },
// };

// /**
//  * Reusable banner ad slot with loading, error, and disabled states.
//  * Renders nothing when ads are disabled so there is no layout shift.
//  */
// export function AdSlot({
//   variant = 'banner',
//   onClose,
//   className = '',
// }: {
//   variant?: AdSlotVariant;
//   onClose?: () => void;
//   className?: string;
// }) {
//   const { adsActive } = useAdContext();
//   const adEnabled = adConfig.enabled && adsActive;
//   const status = useAdLifecycle(adEnabled);

//   if (!adEnabled) return null;
//   const sizes = VARIANT_SIZES[variant];

//   if (status === 'disabled') return null;

//   if (status === 'loading') {
//     return (
//       <div
//         className={`flex ${sizes.container} w-full items-center justify-center gap-2 rounded-xl border border-dashed border-ink-300 bg-ink-50 text-ink-400 dark:border-ink-700 dark:bg-ink-900/50 dark:text-ink-500 ${className}`}
//         aria-label="Ad loading"
//       >
//         <Loader2 size={16} className="animate-spin" />
//         <span className="text-xs font-semibold">Loading ad…</span>
//       </div>
//     );
//   }

//   if (status === 'error') {
//     return (
//       <div
//         className={`flex ${sizes.container} w-full items-center justify-center gap-2 rounded-xl border border-dashed border-error-300 bg-error-50 text-error-500 dark:border-error-800 dark:bg-error-950/30 dark:text-error-400 ${className}`}
//         aria-label="Ad failed to load"
//       >
//         <AlertCircle size={16} />
//         <span className="text-xs font-semibold">Ad unavailable</span>
//       </div>
//     );
//   }

//   return (
//     <div
//       className={`relative flex ${sizes.container} w-full items-center justify-center gap-2 overflow-hidden rounded-xl border border-ink-200 bg-gradient-to-br from-ink-50 to-ink-100 text-ink-500 dark:border-ink-700 dark:from-ink-900 dark:to-ink-800 dark:text-ink-400 ${className}`}
//       aria-label={`${sizes.label} placeholder`}
//     >
//       {onClose && (
//         <button
//           onClick={onClose}
//           className="absolute right-2 top-2 grid h-7 w-7 place-items-center rounded-lg bg-ink-200/60 text-ink-500 transition-colors hover:bg-ink-300 dark:bg-ink-700/60 dark:text-ink-400 dark:hover:bg-ink-600"
//           aria-label="Close ad"
//         >
//           <X size={14} />
//         </button>
//       )}
//       <Megaphone size={18} className="text-primary-500" />
//       <span className="text-xs font-bold uppercase tracking-wide">{sizes.label}</span>
//       <span className="text-[10px] opacity-60">· {sizes.sub} · Test</span>
//     </div>
//   );
// }







import { useEffect, useState } from 'react';
import {
  AdMob,
  BannerAdPluginEvents,
  BannerAdPosition,
  BannerAdSize,
} from '@capacitor-community/admob';
import { Loader2, AlertCircle, X } from 'lucide-react';
import type { AdSlotVariant, AdStatus } from '@/types/ads';
import { adConfig } from '@/config/ads';
import { useAdContext } from '@/context/AdContext';

export function AdSlot({
  variant = 'banner',
  onClose,
  className = '',
}: {
  variant?: AdSlotVariant;
  onClose?: () => void;
  className?: string;
}) {
  const { adsActive } = useAdContext();
  const [status, setStatus] = useState<AdStatus>('idle');

  const isBanner = variant === 'banner';
  const adEnabled =
    adConfig.enabled &&
    adsActive &&
    isBanner &&
    !!adConfig.unitIds.banner;

  useEffect(() => {
    if (!adEnabled) {
      setStatus('disabled');
      return;
    }

    let loadedListener: any;
    let failedListener: any;
    let mounted = true;

    const showBanner = async () => {
      try {
        if (mounted) {
          setStatus('loading');
        }

        console.log('[BANNER AD] Initializing AdMob...');

        await AdMob.initialize();

        loadedListener = await AdMob.addListener(
          BannerAdPluginEvents.Loaded,
          () => {
            console.log('[BANNER AD] Banner loaded successfully');

            if (mounted) {
              setStatus('loaded');
            }
          }
        );

        failedListener = await AdMob.addListener(
          BannerAdPluginEvents.FailedToLoad,
          (error) => {
            console.error('[BANNER AD] Banner failed to load:', error);

            if (mounted) {
              setStatus('error');
            }
          }
        );

        console.log('[BANNER AD] Showing banner...');

        await AdMob.showBanner({
          adId: adConfig.unitIds.banner,
          adSize: BannerAdSize.BANNER,
          position: BannerAdPosition.BOTTOM_CENTER,
          margin: 0,
          isTesting: true,
        });

        console.log('[BANNER AD] showBanner() completed');
      } catch (error) {
        console.error('[BANNER AD] Error:', error);

        if (mounted) {
          setStatus('error');
        }
      }
    };

    showBanner();

    return () => {
      mounted = false;

      if (loadedListener) {
        loadedListener.remove();
      }

      if (failedListener) {
        failedListener.remove();
      }

      AdMob.removeBanner().catch(() => {});
    };
  }, [adEnabled]);

  const handleClose = async () => {
    try {
      await AdMob.hideBanner();
    } catch (error) {
      console.error('[BANNER AD] Hide error:', error);
    }

    if (onClose) {
      onClose();
    }
  };

  if (!adEnabled) {
    return null;
  }

  if (status === 'loading') {
    return (
      <div
        className={`flex h-14 w-full items-center justify-center gap-2 rounded-xl border border-dashed border-ink-300 bg-ink-50 text-ink-400 dark:border-ink-700 dark:bg-ink-900/50 dark:text-ink-500 ${className}`}
        aria-label="Ad loading"
      >
        <Loader2 size={16} className="animate-spin" />
        <span className="text-xs font-semibold">
          Loading ad…
        </span>
      </div>
    );
  }

  if (status === 'error') {
    return (
      <div
        className={`flex h-14 w-full items-center justify-center gap-2 rounded-xl border border-dashed border-error-300 bg-error-50 text-error-500 dark:border-error-800 dark:bg-error-950/30 dark:text-error-400 ${className}`}
        aria-label="Ad failed to load"
      >
        <AlertCircle size={16} />
        <span className="text-xs font-semibold">
          Ad unavailable
        </span>
      </div>
    );
  }

  return (
    <div
      className={`relative h-14 w-full ${className}`}
      aria-label="Banner ad"
    >
      {onClose && (
        <button
          onClick={handleClose}
          className="absolute right-2 top-1 z-10 grid h-7 w-7 place-items-center rounded-lg bg-ink-200/70 text-ink-500 transition-colors hover:bg-ink-300 dark:bg-ink-700/70 dark:text-ink-400 dark:hover:bg-ink-600"
          aria-label="Close ad"
        >
          <X size={14} />
        </button>
      )}
    </div>
  );
}