/// The shader source for the whole app, compiled once when the renderer starts.
///
/// Everything on screen is one of two things:
///   - a "shape": a quad whose pixels are worked out from a formula (a disc, ring, arc, glow,
///     strand segment, or a piece of the picture atlas holding text and photos), or
///   - a "mesh": plain coloured triangles, used for the ribbons.
/// Shapes are drawn many at a time, so a frame is only a handful of draw calls.
enum Shaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Shape {
        float4 place;     // centre.xy in pixels, x axis.xy in pixels
        float4 extent;    // y axis.xy in pixels, half size.xy in the shape's own units
        float4 first;     // colour, premultiplied
        float4 second;    // second colour for gradients, premultiplied
        float4 kind;      // type, pixels per unit, two numbers that depend on the type
        float4 more;      // four more numbers that depend on the type
        float4 uv;        // corner of the atlas to sample, for text and photos
        float4 spare;
    };

    // size of the target, then a transform and tint used when drawing stored meshes
    struct Frame { float2 size; float2 spare; float4 across; float4 down; float4 tint; };

    struct ShapeOut {
        float4 position [[position]];
        float2 local;
        float2 uv;
        float2 unit;
        float4 first [[flat]];
        float4 second [[flat]];
        float4 kind [[flat]];
        float4 more [[flat]];
    };

    vertex ShapeOut shape_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                 const device Shape *shapes [[buffer(0)]], constant Frame &frame [[buffer(1)]]) {
        Shape s = shapes[iid];
        float2 corner = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
        float2 pixel = s.place.xy + s.place.zw * corner.x + s.extent.xy * corner.y;
        ShapeOut o;
        o.position = float4(pixel.x / frame.size.x * 2.0 - 1.0, 1.0 - pixel.y / frame.size.y * 2.0, 0.0, 1.0);
        o.local = corner * s.extent.zw;
        o.unit = corner;
        o.uv = mix(s.uv.xy, s.uv.zw, corner * 0.5 + 0.5);
        o.first = s.first; o.second = s.second; o.kind = s.kind; o.more = s.more;
        return o;
    }

    static inline float cover(float distance, float width) { return clamp(distance / width + 0.5, 0.0, 1.0); }

    fragment float4 shape_fragment(ShapeOut in [[stage_in]], texture2d<float> atlas [[texture(0)]], sampler bilinear [[sampler(0)]]) {
        int type = int(in.kind.x + 0.5);
        float px = 1.0 / max(in.kind.y, 0.0001);          // one pixel, in the shape's own units
        float4 colour = in.first;
        float amount = 1.0;
        if (type == 1) {
            // Disc, ring or arc. kind.z outer radius, kind.w inner radius (below zero for a disc),
            // more.x start angle, more.y sweep, more.z round ends.
            float r = length(in.local);
            amount = cover(in.kind.z - r, px) * cover(r - in.kind.w, px);
            if (in.more.y < 6.2831) {
                float angle = atan2(in.local.y, in.local.x) - in.more.x;
                angle = angle - 6.28318530718 * floor(angle / 6.28318530718);
                float inside = angle <= in.more.y ? 1.0 : 0.0;
                amount *= inside;
                if (in.more.z > 0.5) {
                    float middle = (in.kind.z + in.kind.w) * 0.5, half_width = (in.kind.z - in.kind.w) * 0.5;
                    float2 start = middle * float2(cos(in.more.x), sin(in.more.x));
                    float2 finish = middle * float2(cos(in.more.x + in.more.y), sin(in.more.x + in.more.y));
                    float ends = max(cover(half_width - distance(in.local, start), px), cover(half_width - distance(in.local, finish), px));
                    amount = max(amount, ends);
                }
            }
        } else if (type == 2) {
            // A glow: one colour at radius kind.z fading to another at kind.w. more.x says whether the middle is filled.
            float r = length(in.local);
            float t = clamp((r - in.kind.z) / max(in.kind.w - in.kind.z, 0.0001), 0.0, 1.0);
            colour = mix(in.first, in.second, t);
            amount = cover(in.kind.w - r, px);
            if (in.more.x < 0.5) amount *= cover(r - in.kind.z, px);
        } else if (type == 3) {
            // A piece of a strand: a line along x with half length kind.z and half width kind.w, round ends if more.x.
            float along = abs(in.local.x) - in.kind.z;
            float away = in.more.x > 0.5 ? length(float2(max(along, 0.0), in.local.y)) : abs(in.local.y);
            amount = cover(in.kind.w - away, px);
            if (in.more.x < 0.5) amount *= cover(-along, px);
            colour = mix(in.first, in.second, clamp((in.local.x + in.kind.z) / max(2.0 * in.kind.z, 0.0001), 0.0, 1.0));
        } else if (type == 4) {
            // Text or a photo from the atlas. kind.z 0 for text (tinted), 1 for a photo. kind.w cuts it to a circle.
            float4 texel = atlas.sample(bilinear, in.uv);
            colour = in.kind.z < 0.5 ? in.first * texel.a : texel * in.first.a;
            if (in.kind.w > 0.5) amount = cover((1.0 - length(in.unit)) * in.more.x, px);
        }
        return colour * amount;
    }

    struct MeshIn { float2 position; float2 spare; float4 colour; };
    struct MeshOut { float4 position [[position]]; float4 colour; };

    vertex MeshOut mesh_vertex(uint vid [[vertex_id]], const device MeshIn *points [[buffer(0)]], constant Frame &frame [[buffer(1)]]) {
        MeshOut o;
        float2 q = points[vid].position;
        float2 pixel = float2(dot(frame.across.xy, q) + frame.across.z, dot(frame.down.xy, q) + frame.down.z);
        o.position = float4(pixel.x / frame.size.x * 2.0 - 1.0, 1.0 - pixel.y / frame.size.y * 2.0, 0.0, 1.0);
        o.colour = points[vid].colour * frame.tint;
        return o;
    }

    // A curved strand, shaped here on the GPU: the same quad strip is bent along a curve through one
    // control point, so the app only has to send three points, a width and three colours per strand.
    struct CurveOut { float4 position [[position]]; float away; float half_width [[flat]]; float4 colour; };

    vertex CurveOut curve_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                 const device Shape *shapes [[buffer(0)]], constant Frame &frame [[buffer(1)]]) {
        Shape s = shapes[iid];
        float2 p0 = s.place.xy, control = s.place.zw, p1 = s.extent.xy;
        float u = float(vid >> 1) / 24.0, side = (vid & 1) ? 1.0 : -1.0, w = 1.0 - u;
        float2 point = w * w * p0 + 2.0 * w * u * control + u * u * p1;
        float2 along = 2.0 * w * (control - p0) + 2.0 * u * (p1 - control);
        along = along / max(length(along), 0.0001);
        float reach = s.extent.z + 1.0;
        float2 pixel = point + float2(-along.y, along.x) * side * reach;
        float middle = clamp(s.more.x, 0.001, 0.999);
        CurveOut o;
        o.position = float4(pixel.x / frame.size.x * 2.0 - 1.0, 1.0 - pixel.y / frame.size.y * 2.0, 0.0, 1.0);
        o.away = side * reach;
        o.half_width = s.extent.z;
        o.colour = u < middle ? mix(s.first, s.second, u / middle) : mix(s.second, s.spare, (u - middle) / (1.0 - middle));
        return o;
    }

    fragment float4 curve_fragment(CurveOut in [[stage_in]]) {
        return in.colour * clamp(in.half_width - abs(in.away) + 0.5, 0.0, 1.0);
    }

    fragment float4 mesh_fragment(MeshOut in [[stage_in]]) { return in.colour; }
    """
}
