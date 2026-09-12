import { useEffect, useRef } from 'react';
import { AdMob } from '@capacitor-community/admob';
import { adConfig } from '@/config/ads';
import { useAdContext } from '@/context/AdContext';

export function InterstitialAd({
  open,
  onComplete,
  onSkip,
}: {
  open: boolean;
  onComplete: () => void;
  onSkip: () => void;
}) {
  const { adsActive } = useAdContext();
  const showingRef = useRef(false);

  useEffect(() => {
    if (!open) return;

    if (
      !adConfig.enabled ||
      !adsActive ||
      !adConfig.unitIds.interstitial
    ) {
      onSkip();
      return;
    }

    if (showingRef.current) return;

    const showAd = async () => {
      try {
        showingRef.current = true;

        console.log('Interstitial Ad: Preparing...');

        await AdMob.initialize();

        await AdMob.prepareInterstitial({
          adId: adConfig.unitIds.interstitial,
          isTesting: adConfig.testing,
        });

        console.log('Interstitial Ad: Prepared');

        await AdMob.showInterstitial();

        console.log('Interstitial Ad: Shown');

        onComplete();
      } catch (error) {
        console.error('Interstitial Ad Error:', error);
        onSkip();
      } finally {
        showingRef.current = false;
      }
    };

    showAd();
  }, [open, adsActive, onComplete, onSkip]);

  return null;
}
