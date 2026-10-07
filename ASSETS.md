# Maskot assetleri

Dokuz onaylı kaynak PNG proje kökünde olduğu gibi kalır. Her biri 1254×1254 ve alpha kanalsız koyu bir arka plana sahiptir. `Tools/prepare_assets.py`, NFC normalizasyonuyla gerçek dosya adlarını bulur; ortak 400×400 kaynak çerçevesini alır, koyu zemini parlaklık eşiğiyle alpha'ya çevirir ve üç karakterin beyaz/turuncu/yeşil çizgilerini tutarlı RGB değerlerine eşler.

Her durum için `Resources/Mascots` altında hizalı `body` ve `eyes` katmanları bulunur. Kaynak göz bölgeleri gövdeden çıkarıldığı için üst üste ikinci göz çifti oluşmaz. Durum işaretleri gövde katmanında kalır. Göz katmanı gösterimde en çok 1,7 pt yer değiştirir; gövde sabittir. Hareketi Azalt açıkken göz animasyonu durur.

Kaynaklar değişmeden yeniden üretmek için `Tools/rebuild-assets.sh` çalıştırılır. Script proje içindeki `.build/asset-venv` sanal ortamını kurar, sürümü `Tools/requirements.txt` içinde sabitlenmiş Pillow ve NumPy paketlerini yükler, katmanları, ikonu ve üç kısa sesi yeniden üretir. Doğrudan `python3 Tools/prepare_assets.py` kullanmak için bu iki paket ayrıca kurulmalıdır. Bunlar yalnız geliştirme gereksinimidir; son kullanıcı uygulamasında Python veya Node çalışmaz.

İşlenmiş 9 durum açık, koyu ve desenli zeminlerde karşılaştırmalı görsel olarak incelendi. Beyaz çizgi açık zeminde doğal olarak düşük kontrastlıdır; uygulamadaki küçük koyu gölge okunurluğu destekler. Gerçek macOS masaüstünde görsel QA, test sırasında makine kilitli olduğundan ayrıca yapılmalıdır.

Bildirim sesleri `Tools/generate_sounds.py` ile bu projede sentezlenen kısa WAV dosyalarıdır (`Glass`, `Pop`, `Tink`); üçüncü taraf ses varlığı kullanılmamıştır. Bir olay için yalnız macOS bildirim sesi kullanılır, ayrıca NSSound çalınmaz. Ayarlardaki önizleme ayrıca elle tetiklenir.
