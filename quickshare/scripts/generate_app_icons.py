import os
import math
from PIL import Image, ImageDraw

def create_master_icon():
    size = 1024
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    # 1. Background squircle / rounded rect with gradient feel
    bg = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    bg_draw = ImageDraw.Draw(bg)
    
    radius = 220
    bg_draw.rounded_rectangle([32, 32, size - 32, size - 32], radius=radius, fill=(11, 18, 32, 255))

    # Add inner glowing border
    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    glow_draw = ImageDraw.Draw(glow)
    glow_draw.rounded_rectangle([32, 32, size - 32, size - 32], radius=radius, outline=(34, 211, 238, 180), width=16)
    glow_draw.rounded_rectangle([48, 48, size - 48, size - 48], radius=radius - 12, outline=(52, 211, 153, 120), width=8)
    
    img = Image.alpha_composite(img, bg)
    img = Image.alpha_composite(img, glow)

    # 2. Draw modern P2P sharing symbol
    icon_layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    icon_draw = ImageDraw.Draw(icon_layer)

    cx, cy = size // 2, size // 2

    cyan = (34, 211, 238, 255)
    emerald = (52, 211, 153, 255)

    # Circle nodes
    icon_draw.ellipse([cx - 240, cy - 240, cx - 80, cy - 80], fill=cyan)
    icon_draw.ellipse([cx + 80, cy + 80, cx + 240, cy + 240], fill=emerald)

    # Speed beam
    icon_draw.line([(cx - 160, cy - 160), (cx + 160, cy + 160)], fill=cyan, width=54)

    # Wings
    w1 = [(cx - 40, cy - 180), (cx + 180, cy - 180), (cx + 180, cy + 40), (cx + 100, cy - 60)]
    icon_draw.polygon(w1, fill=cyan)

    w2 = [(cx + 40, cy + 180), (cx - 180, cy + 180), (cx - 180, cy - 40), (cx - 100, cy + 60)]
    icon_draw.polygon(w2, fill=emerald)

    img = Image.alpha_composite(img, icon_layer)
    return img

def create_foreground_icon():
    size = 1024
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    cx, cy = size // 2, size // 2
    cyan = (34, 211, 238, 255)
    emerald = (52, 211, 153, 255)

    # Scale icon slightly down for adaptive safe zone (72% size)
    draw.ellipse([cx - 180, cy - 180, cx - 60, cy - 60], fill=cyan)
    draw.ellipse([cx + 60, cy + 60, cx + 180, cy + 180], fill=emerald)
    draw.line([(cx - 120, cy - 120), (cx + 120, cy + 120)], fill=cyan, width=42)

    w1 = [(cx - 30, cy - 135), (cx + 135, cy - 135), (cx + 135, cy + 30), (cx + 75, cy - 45)]
    draw.polygon(w1, fill=cyan)

    w2 = [(cx + 30, cy + 135), (cx - 135, cy + 135), (cx - 135, cy - 30), (cx - 75, cy + 45)]
    draw.polygon(w2, fill=emerald)

    return img

def main():
    root = "/Users/mrgraimon/Desktop/Share/quickshare"
    master = create_master_icon()
    foreground = create_foreground_icon()
    master.save(os.path.join(root, "master_icon.png"))

    # --- 1. Android Icons ---
    android_res = os.path.join(root, "android/app/src/main/res")
    android_sizes = {
        "mipmap-mdpi": (48, 108),
        "mipmap-hdpi": (72, 162),
        "mipmap-xhdpi": (96, 216),
        "mipmap-xxhdpi": (144, 324),
        "mipmap-xxxhdpi": (192, 432),
    }

    for folder, (dim, fg_dim) in android_sizes.items():
        folder_path = os.path.join(android_res, folder)
        os.makedirs(folder_path, exist_ok=True)

        resized = master.resize((dim, dim), Image.Resampling.LANCZOS)
        resized.save(os.path.join(folder_path, "ic_launcher.png"))

        resized_fg = foreground.resize((fg_dim, fg_dim), Image.Resampling.LANCZOS)
        resized_fg.save(os.path.join(folder_path, "ic_launcher_foreground.png"))
        print(f"Saved Android {folder} ({dim}x{dim}, fg: {fg_dim}x{fg_dim})")

    # Android adaptive icon XMLs
    v26_dir = os.path.join(android_res, "mipmap-anydpi-v26")
    os.makedirs(v26_dir, exist_ok=True)
    adaptive_xml = '''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
</adaptive-icon>'''
    with open(os.path.join(v26_dir, "ic_launcher.xml"), "w") as f:
        f.write(adaptive_xml)
    with open(os.path.join(v26_dir, "ic_launcher_round.xml"), "w") as f:
        f.write(adaptive_xml)

    values_dir = os.path.join(android_res, "values")
    os.makedirs(values_dir, exist_ok=True)
    colors_xml = '''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">#0B1220</color>
</resources>'''
    with open(os.path.join(values_dir, "ic_launcher_background.xml"), "w") as f:
        f.write(colors_xml)
    print("Saved Android adaptive-icon XML configs")

    # --- 2. iOS Icons ---
    ios_icon_dir = os.path.join(root, "ios/Runner/Assets.xcassets/AppIcon.appiconset")
    os.makedirs(ios_icon_dir, exist_ok=True)
    ios_files = {
        "Icon-App-20x20@2x.png": 40,
        "Icon-App-20x20@3x.png": 60,
        "Icon-App-29x29@2x.png": 58,
        "Icon-App-29x29@3x.png": 87,
        "Icon-App-40x40@2x.png": 80,
        "Icon-App-40x40@3x.png": 120,
        "Icon-App-60x60@2x.png": 120,
        "Icon-App-60x60@3x.png": 180,
        "Icon-App-1024x1024@1x.png": 1024,
    }
    for filename, dim in ios_files.items():
        resized = master.resize((dim, dim), Image.Resampling.LANCZOS)
        resized.save(os.path.join(ios_icon_dir, filename))

    # --- 3. macOS Icons ---
    macos_icon_dir = os.path.join(root, "macos/Runner/Assets.xcassets/AppIcon.appiconset")
    os.makedirs(macos_icon_dir, exist_ok=True)
    macos_files = {
        "app_icon_16.png": 16,
        "app_icon_32.png": 32,
        "app_icon_64.png": 64,
        "app_icon_128.png": 128,
        "app_icon_256.png": 256,
        "app_icon_512.png": 512,
        "app_icon_1024.png": 1024,
    }
    for filename, dim in macos_files.items():
        resized = master.resize((dim, dim), Image.Resampling.LANCZOS)
        resized.save(os.path.join(macos_icon_dir, filename))

    macos_json = '''{
  "images" : [
    { "size" : "16x16", "idiom" : "mac", "filename" : "app_icon_16.png", "scale" : "1x" },
    { "size" : "16x16", "idiom" : "mac", "filename" : "app_icon_32.png", "scale" : "2x" },
    { "size" : "32x32", "idiom" : "mac", "filename" : "app_icon_32.png", "scale" : "1x" },
    { "size" : "32x32", "idiom" : "mac", "filename" : "app_icon_64.png", "scale" : "2x" },
    { "size" : "128x128", "idiom" : "mac", "filename" : "app_icon_128.png", "scale" : "1x" },
    { "size" : "128x128", "idiom" : "mac", "filename" : "app_icon_256.png", "scale" : "2x" },
    { "size" : "256x256", "idiom" : "mac", "filename" : "app_icon_256.png", "scale" : "1x" },
    { "size" : "256x256", "idiom" : "mac", "filename" : "app_icon_512.png", "scale" : "2x" },
    { "size" : "512x512", "idiom" : "mac", "filename" : "app_icon_512.png", "scale" : "1x" },
    { "size" : "512x512", "idiom" : "mac", "filename" : "app_icon_1024.png", "scale" : "2x" }
  ],
  "info" : { "version" : 1, "author" : "xcode" }
}'''
    with open(os.path.join(macos_icon_dir, "Contents.json"), "w") as f:
        f.write(macos_json)

    # --- 4. Windows Icon ---
    win_dir = os.path.join(root, "windows/runner/resources")
    os.makedirs(win_dir, exist_ok=True)
    ico_sizes = [(16, 16), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
    ico_images = [master.resize(s, Image.Resampling.LANCZOS) for s in ico_sizes]
    ico_images[0].save(os.path.join(win_dir, "app_icon.ico"), format="ICO", sizes=ico_sizes)

    # --- 5. Linux Icons ---
    linux_dir = os.path.join(root, "linux/assets")
    os.makedirs(linux_dir, exist_ok=True)
    linux_256 = master.resize((256, 256), Image.Resampling.LANCZOS)
    linux_256.save(os.path.join(linux_dir, "app_icon.png"))
    print("All icons successfully generated!")

if __name__ == "__main__":
    main()
