/* quadmath.h -- aarch64 compatibility shim.
 *
 * GCC ships libquadmath only where __float128 is a distinct type, i.e. x86,
 * where long double is the 80-bit x87 format and a separate 128-bit type is
 * therefore needed. On aarch64 there is nothing to port: `long double` IS
 * IEEE 754 binary128 (16 bytes, 113-bit mantissa, max exponent 16384 --
 * verified on this toolchain), so the quad-precision arithmetic is already
 * present in libm under the `long double` names.
 *
 * This header supplies the GCC `*q` spelling on top of that, so sources
 * written against libquadmath compile unmodified. Precision is identical --
 * both are binary128 -- so this is a naming shim, not an emulation, and it
 * costs nothing numerically.
 *
 * Deliberately guarded: on any target that has real libquadmath this header
 * must NOT be used. Put it on the include path for aarch64 only.
 */
#ifndef QUADMATH_SHIM_H
#define QUADMATH_SHIM_H

#if !defined(__aarch64__)
#  error "quadmath shim is aarch64-only; use GCC's real libquadmath elsewhere"
#endif

#include <math.h>
#include <complex.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>   /* strchr, for the format rewrite below */
#include <float.h>

/* binary128 on aarch64 == long double. Assert rather than assume: if a future
 * toolchain changes this, fail loudly instead of silently losing 49 bits. */
#if LDBL_MANT_DIG != 113
#  error "long double is not IEEE binary128 here; the shim would lose precision"
#endif

typedef long double          __float128;
typedef long double _Complex __complex128;

/* Marker for consumers. Because __float128 here is an ALIAS for long double
 * rather than a distinct type, any code that declares its own overload on
 * __float128 (e.g. a custom std::ostream operator<<) now collides with the
 * standard long double overload. Such code must guard those declarations on
 * this macro. __complex128 is unaffected -- C _Complex has no std overload. */
#define QUADMATH_SHIM_FLOAT128_IS_LONG_DOUBLE 1

/* real */
#define fabsq(x)    fabsl(x)
#define logq(x)     logl(x)
#define log10q(x)   log10l(x)
#define expq(x)     expl(x)
#define powq(x, y)  powl((x), (y))
#define sqrtq(x)    sqrtl(x)
#define sinq(x)     sinl(x)
#define cosq(x)     cosl(x)
#define tanq(x)     tanl(x)
#define atanq(x)    atanl(x)
#define atan2q(x, y) atan2l((x), (y))
#define floorq(x)   floorl(x)
#define ceilq(x)    ceill(x)
#define fmaxq(x, y) fmaxl((x), (y))
#define fminq(x, y) fminl((x), (y))
#define fmodq(x, y) fmodl((x), (y))

/* complex.
 *
 * In C the C99 long-double-complex functions (creall, conjl, csqrtl, ...) are
 * declared and we map straight onto them. In C++ they are NOT: <complex.h>
 * defers to <complex>, and the C99 names are not visible. GCC still supports
 * the _Complex TYPE in C++ as an extension, so __complex128 stays a valid
 * type; we just have to supply the operations ourselves. Route them through
 * std::complex<long double>, which is the same binary128 representation. */
#ifdef __cplusplus

#include <complex>

static inline long double quadmath_shim_creal(__complex128 z) { return __real__ z; }
static inline long double quadmath_shim_cimag(__complex128 z) { return __imag__ z; }

static inline std::complex<long double> quadmath_shim_to_std(__complex128 z)
{ return std::complex<long double>(__real__ z, __imag__ z); }

static inline __complex128 quadmath_shim_from_std(const std::complex<long double>& s)
{ __complex128 r; __real__ r = s.real(); __imag__ r = s.imag(); return r; }

static inline long double quadmath_shim_cabs(__complex128 z)
{ return std::abs(quadmath_shim_to_std(z)); }

static inline __complex128 quadmath_shim_conj(__complex128 z)
{ __complex128 r; __real__ r = __real__ z; __imag__ r = -(__imag__ z); return r; }

static inline __complex128 quadmath_shim_clog(__complex128 z)
{ return quadmath_shim_from_std(std::log(quadmath_shim_to_std(z))); }

static inline __complex128 quadmath_shim_cexp(__complex128 z)
{ return quadmath_shim_from_std(std::exp(quadmath_shim_to_std(z))); }

static inline __complex128 quadmath_shim_csqrt(__complex128 z)
{ return quadmath_shim_from_std(std::sqrt(quadmath_shim_to_std(z))); }

static inline __complex128 quadmath_shim_cpow(__complex128 z, __complex128 w)
{ return quadmath_shim_from_std(std::pow(quadmath_shim_to_std(z),
                                         quadmath_shim_to_std(w))); }

#define cabsq(z)    quadmath_shim_cabs(z)
#define crealq(z)   quadmath_shim_creal(z)
#define cimagq(z)   quadmath_shim_cimag(z)
#define conjq(z)    quadmath_shim_conj(z)
#define clogq(z)    quadmath_shim_clog(z)
#define cexpq(z)    quadmath_shim_cexp(z)
#define csqrtq(z)   quadmath_shim_csqrt(z)
#define cpowq(z, w) quadmath_shim_cpow((z), (w))

#else  /* C: the C99 long-double-complex functions are declared */

#define cabsq(z)    cabsl(z)
#define crealq(z)   creall(z)
#define cimagq(z)   cimagl(z)
#define conjq(z)    conjl(z)
#define clogq(z)    clogl(z)
#define cexpq(z)    cexpl(z)
#define csqrtq(z)   csqrtl(z)
#define cpowq(z, w) cpowl((z), (w))

#endif

/* Math constants. libquadmath spells them M_*q; glibc's binary128 values are
 * the M_*l set (same type, same precision here). Defined unconditionally
 * rather than guarded on __USE_GNU so consumers do not have to care. */
#ifndef M_PIq
#  define M_PIq     3.141592653589793238462643383279502884L
#endif
#ifndef M_Eq
#  define M_Eq      2.718281828459045235360287471352662498L
#endif
#ifndef M_LN2q
#  define M_LN2q    0.693147180559945309417232121458176568L
#endif
#ifndef M_LN10q
#  define M_LN10q   2.302585092994045684017991454684364208L
#endif
#ifndef M_SQRT2q
#  define M_SQRT2q  1.414213562373095048801688724209698079L
#endif
#ifndef M_PI_2q
#  define M_PI_2q   1.570796326794896619231321691639751442L
#endif
#ifndef M_PI_4q
#  define M_PI_4q   0.785398163397448309615660845819875721L
#endif

/* limits, spelled as libquadmath does */
#define FLT128_MAX      LDBL_MAX
#define FLT128_MIN      LDBL_MIN
#define FLT128_EPSILON  LDBL_EPSILON
#define FLT128_DIG      LDBL_DIG
#define FLT128_MANT_DIG LDBL_MANT_DIG

/* libquadmath spells a quad conversion with the length modifier Q, glibc
 * spells the identical thing L. Rewrite the format so callers need no change.
 *
 * The Q sits where a length modifier goes -- AFTER flags, width and precision
 * -- so "%.36Qf" and "%+20.5Qe" must both be handled, not just a bare "%Q".
 * Walk each conversion spec properly rather than pattern-matching "%Q". */
static inline int
quadmath_snprintf(char *str, size_t size, const char *format, ...)
{
    char fmt[512];
    size_t i = 0, j = 0;

    while (format[i] && j + 2 < sizeof fmt) {
        if (format[i] != '%') { fmt[j++] = format[i++]; continue; }

        fmt[j++] = format[i++];              /* the '%' */
        if (format[i] == '%') { fmt[j++] = format[i++]; continue; }  /* "%%" */

        /* flags, width, precision, '*' -- copy through untouched */
        while (format[i] && j + 2 < sizeof fmt &&
               (strchr("-+ #0'", format[i]) != NULL ||
                (format[i] >= '0' && format[i] <= '9') ||
                format[i] == '.' || format[i] == '*'))
            fmt[j++] = format[i++];

        /* length modifier: Q -> L, everything else copied through */
        if (format[i] == 'Q') { fmt[j++] = 'L'; i++; }
        else
            while (format[i] && j + 2 < sizeof fmt &&
                   strchr("hlLjzt", format[i]) != NULL)
                fmt[j++] = format[i++];

        if (format[i] && j + 2 < sizeof fmt) fmt[j++] = format[i++];  /* conversion */
    }
    fmt[j] = '\0';

    va_list ap;
    va_start(ap, format);
    int n = vsnprintf(str, size, fmt, ap);
    va_end(ap);
    return n;
}

static inline __float128
strtoflt128(const char *s, char **endptr)
{
    return strtold(s, endptr);
}

#endif /* QUADMATH_SHIM_H */
