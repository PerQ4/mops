#include <flutter/runtime_effect.glsl>

// Liquid backdrop — «жидкий» фон полноэкранного плеера.
//
// Идея взята у shredos67/swiftify (`LiquidBackdrop.qml`, `shaders/`): фон плеера —
// медленно текущая жидкость из цветов обложки. Код свой: их GLSL написан под
// Qt/QRhi, здесь — runtime effect Flutter, где доступны только float-униформы и
// FlutterFragCoord().
//
// Дешевизна намеренно важнее красоты: хеш без sin (на слабой машине sin на
// каждый пиксель заметно дороже), три октавы вместо шести, пять вызовов fbm на
// пиксель. Анимацию двигает не шейдер, а uTime: время передаёт виджет, и на
// паузе оно не растёт (см. `lib/widgets/liquid_backdrop.dart`), поэтому кадры на
// простое не тратятся.

uniform vec2 uSize;   // размер области в тех же единицах, что FlutterFragCoord
uniform float uTime;  // секунды с начала показа (на паузе стоит)
uniform vec3 uColorA; // цвет 1 палитры обложки
uniform vec3 uColorB; // цвет 2
uniform vec3 uColorC; // цвет 3

out vec4 fragColor;

// Хеш без transcendentals: только умножение, сложение и fract.
float hash(vec2 p) {
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}

float valueNoise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  // Кубическое сглаживание: границы ячеек не видны.
  vec2 u = f * f * (3.0 - 2.0 * f);
  float a = hash(i);
  float b = hash(i + vec2(1.0, 0.0));
  float c = hash(i + vec2(0.0, 1.0));
  float d = hash(i + vec2(1.0, 1.0));
  return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Три октавы: одной мало — видны «клетки», больше — не оправдано по цене.
float fbm(vec2 p) {
  float sum = 0.0;
  float amp = 0.5;
  for (int i = 0; i < 3; i++) {
    sum += amp * valueNoise(p);
    p *= 2.07;
    amp *= 0.5;
  }
  return sum;
}

void main() {
  vec2 uv = FlutterFragCoord().xy / uSize;
  // Растягиваем по горизонтали по пропорции области: круглая жидкость в широком
  // окне выглядела бы сплюснутой.
  vec2 p = vec2(uv.x * (uSize.x / max(uSize.y, 1.0)), uv.y) * 2.2;
  float t = uTime;

  // Доменное искажение: шум смещает сам себя, поэтому вместо «облаков»
  // получаются тянущиеся волокна — и они медленно ползут со временем.
  vec2 q = vec2(
      fbm(p + vec2(0.0, t * 0.045)),
      fbm(p + vec2(5.2, 1.3) - vec2(t * 0.032, 0.0)));
  float f = fbm(p + 2.6 * q + vec2(1.7, 9.2));

  vec3 color = mix(uColorA, uColorB, clamp(f * 1.35, 0.0, 1.0));
  color = mix(color, uColorC, clamp(q.y * 0.7, 0.0, 1.0));

  // Виньетка: края темнее, середина «подсвечена» — как подсветка под жидкостью.
  float vignette = smoothstep(1.25, 0.2, length(uv - 0.5));
  color *= 0.80 + 0.30 * vignette;

  fragColor = vec4(color, 1.0);
}
