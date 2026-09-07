# Cadre

macOS için ekran görüntüsü ve ekran kaydı aracı. Swift + AppKit + ScreenCaptureKit.
Menü çubuğunda yaşar. Dock simgesi Settings → General altından kapatılır.

## Kurulum

```bash
Scripts/kur.sh            # sürüm derlemesi yap, /Applications altına kur, başlat
```

Kurulumdan sonra Cadre normal bir uygulamadır: Launchpad'de görünür, Spotlight bulur.
Her oturum açılışında kendiliğinden başlaması için Settings → General →
**Open Cadre at login** anahtarını aç. Kayıt macOS'un oturum açma ögelerine yazılır.

## Geliştirme

```bash
Scripts/run.sh            # derle, paketle, build/ içinden başlat
Scripts/run.sh release    # sürüm derlemesi
Scripts/bundle.sh         # yalnız Cadre.app üret
swift build               # yalnız derle
```

İlk açılışta macOS ekran kaydı izni ister.
Sistem Ayarları → Gizlilik ve Güvenlik → Ekran Kaydı → Cadre.

## Öntanımlı kısayollar

| Kısayol | İş |
| ------- | -- |
| ⌘⇧4 | Alan yakala |
| ⌃⇧5 | Pencere yakala |
| ⌃⇧3 | Tüm ekranı yakala |
| ⌃⇧6 | Son alanı yeniden yakala |
| ⌃⇧7 | Ekranı kaydet, sonra durdur |
| ⌃⇧8 | Ekrandaki yazıyı oku |

Alan yakalama macOS'un ⌘⇧4 tuşunu alır. macOS'un kendi kısayolu açık kalırsa iki araç
birlikte açılır. Onu bir kez kapat:

```bash
Scripts/native-kisayol.sh kapat   # geri açmak için: ac
```

Kalan kısayollar ⌃⇧ kullanır, macOS ile çakışmazlar.
Kısayollar Ayarlar → Kısayollar altında değişir.

## Seçim katmanı

Seçim başlarken ekran bir kez yakalanır ve donmuş kare katmanın altına serilir.
Büyüteç gerçek pikselleri gösterir, renk okunur, onaydan sonra kırpma anında biter.

| Tuş | İş |
| --- | -- |
| Sürükle | Alan seç |
| Shift + sürükle | Kare seç |
| Space | Pencere kipine geç |
| Ok tuşları | Seçimi kaydır |
| Shift + ok | Seçimi büyüt veya küçült |
| ⌘A | Tüm ekranı seç |
| Return | Onayla |
| Esc | Çık |

## Düzenleyici

Ok, çizgi, dikdörtgen, elips, kalem, fosforlu, yazı, numara, bulanıklaştırma,
pikselleştirme ve kırpma. Geri al ⌘Z, kaydet ⌘S.
Açıklamalar görüntünün piksel uzayında durur, bu yüzden kaydedilen dosya ekrandakinin aynısıdır.

Esc her basışta bir adım geri alır: yazı kutusu → kırpma → seçim → araç.
Son basışta araç Select'e döner.

## Mimari

```
Sources/Cadre/
  App/          NSApplication kurulumu, kısayol kaydı
  Core/         tercihler, koordinat çevirisi, geçmiş, global kısayollar
  Capture/      ScreenCaptureKit sarmalayıcı, seçim katmanı, akış yöneticisi
  Editor/       açıklama modeli, çizici, tuval, pencere
  Recording/    SCStream → AVAssetWriter, GIF çevirici
  Settings/     ayarlar penceresi, kısayol yakalayıcı
  Text/         Vision ile yazı okuma
  UI/           menü çubuğu, önizleme kartı, bilgi balonu
```

macOS iki koordinat sistemi kullanır. Çeviri yalnız `Core/CoordinateSpace.swift`
içinde yapılır; başka yerde elle ters çevirme yazma.

## Bilinen boşluklar

- Kaydırmalı yakalama yok.
- Bulut yükleme yok.
- Ad-hoc imza kullanılır. İkili her değiştiğinde macOS ekran kaydı iznini yeniden sorabilir.
