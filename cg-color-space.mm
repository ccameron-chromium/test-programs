// clang++ cg-color-space.mm -framework CoreGraphics && ./a.out   

#include <CoreGraphics/CoreGraphics.h>
int main(int argc, char* arg[]) {
  {
    CGFloat src_components[4] = {1, 0, 0, 1};
    CGColorSpaceRef src_space = CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3);
    CGColorRef src_color = CGColorCreate(src_space, src_components);

    CGColorSpaceRef dst_space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGColorRef dst_color = CGColorCreateCopyByMatchingToColorSpace(
        dst_space, kCGRenderingIntentRelativeColorimetric, src_color, nullptr);
    const CGFloat* x =  CGColorGetComponents(dst_color);
    printf("color(p3 1 0 0) -> color(srgb %f %f %f)\n", x[0], x[1], x[2]);
  }
  return 0;
}
