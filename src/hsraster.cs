// Heptapod L Studio raster decoder (orthography HL-1.1). C# 5 / .NET Framework 4.x compatible.
// Reads a grayscale image of a native logogram and recovers its glyph primitives
// by fitting the Heptapod L glyph model (direction, curl, length, barbs) to the ink.
using System;
using System.Collections.Generic;

public class HsGlyphHit
{
    public double[] Base; public List<int> Pixels; public double OwnFraction;
    public int Band; public double Angle; public int D; public int C; public int B; public int L; public int Value;
    public double[] BarbCov; public double PrimaryScore; public double PrimaryMargin; public double BarbScore; public double BarbMargin; public double Confidence;
}
public class HsBar { public int Band; public double Angle; public bool IsStart; public double Strength; }
public class HsRasterResult
{
    public bool Ok; public string Reason; public int Width; public int Height; public bool DarkBackground;
    public double Cx; public double Cy; public double Scale; public double[] BandR;
    public List<HsGlyphHit> Glyphs = new List<HsGlyphHit>();
    public List<HsBar> Bars = new List<HsBar>();
    public List<string> Unresolved = new List<string>();
    public int InkPixels;
}

public static class HsRaster
{
    // geometry (must match server.ps1)
    public static double R0 = 240, BandStep = 220, PriW = 13, BarbLen = 27, BarbW = 7, InClusterPx = 32;
    public static double[] Len = new double[] { 40, 64, 92 };
    public static int NPri = 18, NBarb = 8;
    public static double Threshold = 0.68;

    static int W, H; static bool[] M;

    public static byte[] BgrToGray(byte[] bgr, int w, int h, int stride, int bpp)
    {
        byte[] g = new byte[w * h];
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
            {
                int i = y * stride + x * bpp;
                g[y * w + x] = (byte)((bgr[i] * 29 + bgr[i + 1] * 150 + bgr[i + 2] * 77) >> 8);
            }
        return g;
    }

    static byte[] Downscale(byte[] g, int w, int h, int f, out int nw, out int nh)
    {
        nw = w / f; nh = h / f; byte[] o = new byte[nw * nh];
        for (int y = 0; y < nh; y++) for (int x = 0; x < nw; x++)
            {
                int s = 0; for (int dy = 0; dy < f; dy++) for (int dx = 0; dx < f; dx++) s += g[(y * f + dy) * w + x * f + dx];
                o[y * nw + x] = (byte)(s / (f * f));
            }
        return o;
    }

    static bool At(bool[] m, double x, double y)
    {
        int ix = (int)Math.Round(x), iy = (int)Math.Round(y);
        if (ix < 0 || iy < 0 || ix >= W || iy >= H) return false;
        return m[iy * W + ix];
    }

    static bool[] Dilate(bool[] m, int r)
    {
        if (r <= 0) return m;
        bool[] t = new bool[W * H]; bool[] o = new bool[W * H];
        for (int y = 0; y < H; y++)
        {
            int cnt = 0;
            for (int x = -r; x < W; x++)
            {
                int add = x + r; if (add < W && m[y * W + add]) cnt++;
                int rem = x - r - 1; if (rem >= 0 && m[y * W + rem]) cnt--;
                if (x >= 0) t[y * W + x] = cnt > 0;
            }
        }
        for (int x = 0; x < W; x++)
        {
            int cnt = 0;
            for (int y = -r; y < H; y++)
            {
                int add = y + r; if (add < H && t[add * W + x]) cnt++;
                int rem = y - r - 1; if (rem >= 0 && t[rem * W + x]) cnt--;
                if (y >= 0) o[y * W + x] = cnt > 0;
            }
        }
        return o;
    }

    static void Pt(double cx, double cy, double r, double th, out double x, out double y)
    {
        double t = th * Math.PI / 180.0; x = cx + r * Math.Sin(t); y = cy - r * Math.Cos(t);
    }

    static void Centerline(double x0, double y0, double th, int d, int c, double len, double[] X, double[] Y)
    {
        double t0 = th * Math.PI / 180.0;
        double ux = Math.Sin(t0), uy = -Math.Cos(t0), vx = Math.Cos(t0), vy = Math.Sin(t0);
        double dd = d == 1 ? -1.0 : 1.0, cc = c == 1 ? -1.0 : 1.0;
        for (int i = 0; i < NPri; i++)
        {
            double t = i / (NPri - 1.0);
            double a = t - 0.25 * t * t, b = 0.5 * Math.Pow(t, 2.2);
            X[i] = x0 + ux * dd * len * a + vx * cc * len * b;
            Y[i] = y0 + uy * dd * len * a + vy * cc * len * b;
        }
    }

    static double CoverCurve(bool[] m, double[] X, double[] Y, double t0, double t1, int samples)
    {
        int n = X.Length, hit = 0, tot = 0;
        for (int s = 0; s < samples; s++)
        {
            double t = t0 + (t1 - t0) * s / (samples - 1.0);
            double fi = t * (n - 1); int i = (int)Math.Floor(fi); if (i >= n - 1) i = n - 2; double f = fi - i;
            double x = X[i] + (X[i + 1] - X[i]) * f, y = Y[i] + (Y[i + 1] - Y[i]) * f;
            tot++; if (At(m, x, y)) hit++;
        }
        return tot == 0 ? 0 : (double)hit / tot;
    }

    // checks that the stroke has primary-like thickness along t = 0.25..0.6 (barbs are much thinner)
    static double CoverWidth(double[] X, double[] Y, double s)
    {
        int n = X.Length, hit = 0, tot = 0;
        for (int q = 0; q < 12; q++)
        {
            double t = 0.25 + 0.35 * q / 11.0;
            double fi = t * (n - 1); int i = (int)Math.Floor(fi); double f = fi - i;
            double x = X[i] + (X[i + 1] - X[i]) * f, y = Y[i] + (Y[i + 1] - Y[i]) * f;
            double dx = X[i + 1] - X[i], dy = Y[i + 1] - Y[i], m = Math.Sqrt(dx * dx + dy * dy); if (m == 0) m = 1;
            double nx = -dy / m, ny = dx / m;
            double hw = PriW * s * Math.Pow(1 - t, 0.9) * (1 + 0.35 * Math.Sin(Math.PI * t)) / 2.0 * 0.55;
            tot += 2; if (At(M, x + nx * hw, y + ny * hw)) hit++; if (At(M, x - nx * hw, y - ny * hw)) hit++;
        }
        return (double)hit / tot;
    }

    static void Barb(double[] PX, double[] PY, int k, int side, double s, double[] X, double[] Y)
    {
        double dx = PX[k + 1] - PX[k - 1], dy = PY[k + 1] - PY[k - 1], m = Math.Sqrt(dx * dx + dy * dy);
        double tx = dx / m, ty = dy / m, ang = 50.0 * Math.PI / 180.0 * side;
        double bx = tx * Math.Cos(ang) - ty * Math.Sin(ang), by = tx * Math.Sin(ang) + ty * Math.Cos(ang);
        double px = -by * side, py = bx * side;
        for (int i = 0; i < NBarb; i++)
        {
            double t = i / (NBarb - 1.0);
            X[i] = PX[k] + bx * BarbLen * s * t + px * 4.0 * s * t * t;
            Y[i] = PY[k] + by * BarbLen * s * t + py * 4.0 * s * t * t;
        }
    }

    public static HsRasterResult Analyze(byte[] gray, int w, int h)
    {
        // try the dominant background first, then the second most common tone (e.g. a paper logogram inside a dark screenshot)
        int[] gh = new int[256]; for (int i = 0; i < gray.Length; i++) gh[gray[i]]++;
        double[] sm = new double[256];
        for (int v = 0; v < 256; v++) for (int q = -3; q <= 3; q++) { int vv = v + q; if (vv >= 0 && vv < 256) sm[v] += gh[vv]; }
        int m1 = 0; for (int v = 1; v < 256; v++) if (sm[v] > sm[m1]) m1 = v;
        int m2 = -1; for (int v = 0; v < 256; v++) if (Math.Abs(v - m1) >= 80 && (m2 < 0 || sm[v] > sm[m2])) m2 = v;
        BgOverride = m1; HsRasterResult r1 = Core(gray, w, h, 0);
        if (Usable(r1) || m2 < 0 || sm[m2] < 0.03 * gray.Length) { BgOverride = -1; return r1; }
        // crop to the block where the second tone dominates (a logogram panel inside a screenshot)
        int x0 = 0, x1 = w - 1, y0 = 0, y1 = h - 1;
        {
            int[] rc = new int[h], cc = new int[w];
            for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) if (Math.Abs(gray[y * w + x] - m2) <= 25) { rc[y]++; cc[x]++; }
            LongestRun(rc, 0.25 * w, out y0, out y1); LongestRun(cc, 0.25 * h, out x0, out x1);
        }
        int cw = x1 - x0 + 1, ch = y1 - y0 + 1;
        if (cw < 120 || ch < 120) { cw = w; ch = h; x0 = 0; y0 = 0; }
        byte[] crop = new byte[cw * ch];
        for (int y = 0; y < ch; y++) Array.Copy(gray, (y + y0) * w + x0, crop, y * cw, cw);
        BgOverride = m2; HsRasterResult r2 = Core(crop, cw, ch, 0); BgOverride = -1;
        if (!Usable(r2)) return r1;
        r2.Cx += x0; r2.Cy += y0; r2.Width = w; r2.Height = h;
        return r2;
    }
    static int BgOverride = -1;
    static void LongestRun(int[] cnt, double thr, out int a, out int b)
    {
        a = 0; b = cnt.Length - 1; int bestLen = 0, cur = -1;
        for (int i = 0; i <= cnt.Length; i++)
        {
            bool on = i < cnt.Length && cnt[i] >= thr;
            if (on && cur < 0) cur = i;
            if (!on && cur >= 0) { if (i - cur > bestLen) { bestLen = i - cur; a = cur; b = i - 1; } cur = -1; }
        }
    }
    static bool Usable(HsRasterResult r)
    {
        if (!r.Ok || r.Glyphs.Count == 0) return false;
        bool st = false; foreach (HsBar b in r.Bars) if (b.IsStart) st = true;
        if (!st) return false;
        List<double> f = new List<double>(); foreach (HsGlyphHit g in r.Glyphs) f.Add(g.PrimaryScore); f.Sort();
        return f[f.Count / 2] >= 0.55;
    }

    static HsRasterResult Core(byte[] gray, int w, int h, int depth)
    {
        HsRasterResult res = new HsRasterResult();
        int f = 1; while (Math.Max(w, h) / f > 2200) f++;
        if (f > 1) { int nw, nh; gray = Downscale(gray, w, h, f, out nw, out nh); w = nw; h = nh; }
        W = w; H = h; res.Width = w; res.Height = h;
        if (w < 120 || h < 120) { res.Reason = "Image too small to interpret."; return res; }

        // 1. background and ink polarity from the border
        List<int> border = new List<int>();
        for (int x = 0; x < w; x += 2) { border.Add(gray[x]); border.Add(gray[(h - 1) * w + x]); }
        for (int y = 0; y < h; y += 2) { border.Add(gray[y * w]); border.Add(gray[y * w + w - 1]); }
        border.Sort();
        // background = most common grey level (robust to screenshots with margins); border median as tie-break
        int[] ghist = new int[256]; for (int i = 0; i < w * h; i++) ghist[gray[i]]++;
        int mode = 0; double mbest = -1;
        for (int v = 0; v < 256; v++) { double sm2 = 0; for (int q = -3; q <= 3; q++) { int vv = v + q; if (vv >= 0 && vv < 256) sm2 += ghist[vv]; } if (sm2 > mbest) { mbest = sm2; mode = v; } }
        double bg = BgOverride >= 0 ? BgOverride : mode;
        res.DarkBackground = bg < 128;
        double range = res.DarkBackground ? (255 - bg) : bg; if (range < 40) { res.Reason = "No usable contrast between ink and background."; return res; }
        M = new bool[w * h]; int ink = 0;
        for (int i = 0; i < w * h; i++)
        {
            double v = res.DarkBackground ? (gray[i] - bg) / range : (bg - gray[i]) / range;
            if (v >= Threshold) { M[i] = true; ink++; }
        }
        res.InkPixels = ink;
        if (ink < 200) { res.Reason = "Almost no solid ink found."; return res; }

        // 2. centre: maximise radial concentration of ink
        List<int> px = new List<int>(), py = new List<int>();
        int step = Math.Max(1, ink / 40000);
        int cnt = 0; double sx = 0, sy = 0;
        for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) if (M[y * w + x]) { if (cnt % step == 0) { px.Add(x); py.Add(y); } cnt++; sx += x; sy += y; }
        double cx = sx / ink, cy = sy / ink;
        int maxR = (int)Math.Sqrt(w * w + h * h) + 2;
        double bestScore = -1, bcx = cx, bcy = cy;
        double span = Math.Max(w, h) / 12.0;
        double[] steps = new double[] { span / 10.0, span / 50.0, 0.5 };
        for (int pass = 0; pass < 3; pass++)
        {
            double st = Math.Max(0.5, steps[pass]); double ox = bcx, oy = bcy;
            for (int iy = -10; iy <= 10; iy++) for (int ix = -10; ix <= 10; ix++)
                {
                    double tx = ox + ix * st, ty = oy + iy * st;
                    int[] hist = new int[maxR];
                    for (int k = 0; k < px.Count; k++) { double ddx = px[k] - tx, ddy = py[k] - ty; int r = (int)Math.Sqrt(ddx * ddx + ddy * ddy); hist[r]++; }
                    int best = 0; for (int r = 20; r < maxR - 2; r++) { int v = hist[r - 1] + hist[r] + hist[r + 1]; double nv = v / Math.Sqrt(r); if (nv > best) best = (int)nv; }
                    if (best > bestScore) { bestScore = best; bcx = tx; bcy = ty; }
                }
        }
        cx = bcx; cy = bcy;

        // 3. band radii from normalised radial density
        double[] dens = new double[maxR];
        for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) if (M[y * w + x]) { double ddx = x - cx, ddy = y - cy; int r = (int)Math.Sqrt(ddx * ddx + ddy * ddy); if (r < maxR) dens[r] += 1; }
        for (int r = 1; r < maxR; r++) dens[r] /= (2 * Math.PI * r);
        double[] sm = new double[maxR];
        for (int r = 3; r < maxR - 3; r++) { double s2 = 0; for (int q = -3; q <= 3; q++) s2 += dens[r + q]; sm[r] = s2 / 7; }
        double peak = 0; for (int r = 20; r < maxR - 3; r++) if (sm[r] > peak) peak = sm[r];
        List<int> peaks = new List<int>();
        for (int r = 20; r < maxR - 4; r++)
            if (sm[r] >= 0.45 * peak && sm[r] >= sm[r - 1] && sm[r] > sm[r + 1])
            {
                bool far = true; foreach (int p in peaks) if (Math.Abs(p - r) < 25) far = false;
                if (far) peaks.Add(r);
            }
        if (peaks.Count == 0) { res.Reason = "No circular sentence ring detected."; return res; }
        // pick the smallest peak that yields a consistent band ladder
        double R0img = peaks[0]; double s = R0img / R0;
        List<double> bands = new List<double>();
        for (int k = 0; k < 12; k++)
        {
            double expect = (R0 + BandStep * k) * s; bool found = false;
            foreach (int p in peaks) if (Math.Abs(p - expect) < 0.08 * expect) { found = true; }
            if (found) bands.Add(expect); else break;
        }
        // refine each band radius and centre with an algebraic circle fit on ring pixels
        for (int pass = 0; pass < 2; pass++)
        {
            double Sx = 0, Sy = 0, Sxx = 0, Syy = 0, Sxy = 0, Sxz = 0, Syz = 0, Sz = 0; int n = 0;
            double Rb = bands[0];
            for (int y = 0; y < h; y++) for (int x = 0; x < w; x++)
                    if (M[y * w + x])
                    {
                        double ddx = x - cx, ddy = y - cy, r = Math.Sqrt(ddx * ddx + ddy * ddy);
                        if (Math.Abs(r - Rb) < 6 * s) { double z = x * x + y * y; Sx += x; Sy += y; Sxx += x * x; Syy += y * y; Sxy += x * y; Sxz += x * z; Syz += y * z; Sz += z; n++; }
                    }
            if (n < 50) break;
            // solve [Sxx Sxy Sx; Sxy Syy Sy; Sx Sy n] [D E F] = -[Sxz Syz Sz]
            double[,] A = new double[3, 4] { { Sxx, Sxy, Sx, -Sxz }, { Sxy, Syy, Sy, -Syz }, { Sx, Sy, n, -Sz } };
            for (int i = 0; i < 3; i++)
            {
                int pv = i; for (int j = i + 1; j < 3; j++) if (Math.Abs(A[j, i]) > Math.Abs(A[pv, i])) pv = j;
                for (int k = 0; k < 4; k++) { double tmp = A[i, k]; A[i, k] = A[pv, k]; A[pv, k] = tmp; }
                for (int j = 0; j < 3; j++) if (j != i) { double fct = A[j, i] / A[i, i]; for (int k = 0; k < 4; k++) A[j, k] -= fct * A[i, k]; }
            }
            double D = A[0, 3] / A[0, 0], E = A[1, 3] / A[1, 1], F = A[2, 3] / A[2, 2];
            cx = -D / 2; cy = -E / 2; double rr = Math.Sqrt(cx * cx + cy * cy - F);
            if (double.IsNaN(rr)) break;
            s = rr / R0;
            for (int k = 0; k < bands.Count; k++) bands[k] = (R0 + BandStep * k) * s;
        }
        res.Cx = cx; res.Cy = cy; res.Scale = s; res.BandR = bands.ToArray();
        if (s < 0.25) { res.Reason = "Logogram too small in the image (scale " + s.ToString("0.00") + ")."; return res; }
        if (s > 1.35 && depth == 0)
        {
            int fct = (int)Math.Ceiling(s / 1.15); int nw2, nh2;
            byte[] g2 = Downscale(gray, w, h, fct, out nw2, out nh2);
            HsRasterResult r2 = Core(g2, nw2, nh2, 1);
            r2.Cx = r2.Cx * fct + (fct - 1) / 2.0; r2.Cy = r2.Cy * fct + (fct - 1) / 2.0; r2.Scale *= fct;
            if (r2.BandR != null) for (int k = 0; k < r2.BandR.Length; k++) r2.BandR[k] *= fct;
            r2.Width = w; r2.Height = h; return r2;
        }


        // 4. per band: bases and bars from the two sampling rows
        for (int b = 0; b < bands.Count; b++)
        {
            double R = bands[b]; double rowOff = 13 * s;
            int na = (int)(2 * Math.PI * R / 0.5); double da = 360.0 / na;
            bool[] outR = new bool[na], inR = new bool[na];
            for (int i = 0; i < na; i++)
            {
                double th = i * da, x, y; bool o = false, n2 = false;
                for (int q = -1; q <= 1; q++)
                {
                    Pt(cx, cy, R + rowOff + q, th, out x, out y); if (At(M, x, y)) o = true;
                    Pt(cx, cy, R - rowOff + q, th, out x, out y); if (At(M, x, y)) n2 = true;
                }
                outR[i] = o; inR[i] = n2;
            }
            List<double[]> outRuns = Runs(outR, da, R), inRuns = Runs(inR, da, R);
            double pxPerDeg = Math.PI * R / 180.0;
            List<double[]> bases = new List<double[]>(); // angle, dir, width
            bool[] outUsed = new bool[outRuns.Count], inUsed = new bool[inRuns.Count];
            for (int i = 0; i < outRuns.Count; i++)
                for (int j = 0; j < inRuns.Count; j++)
                {
                    if (inUsed[j]) continue;
                    double dAng = Math.Abs(AngDiff(outRuns[i][0], inRuns[j][0])) * pxPerDeg;
                    if (dAng < 5 * s && outRuns[i][1] < 16 * s && inRuns[j][1] < 16 * s)
                    {
                        double a = AngMid(outRuns[i][0], inRuns[j][0]);
                        // start bar reaches R +/- 24s on both sides
                        int hitO = 0, hitI = 0;
                        for (double off = -4 * s; off <= 4 * s; off += 0.5)
                        {
                            double x, y, th = a + off / pxPerDeg;
                            Pt(cx, cy, R + 24 * s, th, out x, out y); if (At(M, x, y)) hitO++;
                            Pt(cx, cy, R - 24 * s, th, out x, out y); if (At(M, x, y)) hitI++;
                        }
                        bool isStart = (hitO > 0 && hitI > 0);
                        // a boundary stub ends at 20s: ink at 24s on only one side means a glyph stroke, not a bar
                        if (!isStart && (hitO > 0 || hitI > 0)) continue;
                        if (!isStart)
                        {
                            // a boundary bar is a short straight stub; if either half fits a full glyph it is a glyph, not a bar
                            Claim = null;
                            HsGlyphHit go = FitGlyph(new double[] { outRuns[i][0], 0, outRuns[i][1] }, b, R, cx, cy, s, pxPerDeg);
                            HsGlyphHit gi2 = FitGlyph(new double[] { inRuns[j][0], 1, inRuns[j][1] }, b, R, cx, cy, s, pxPerDeg);
                            if ((go != null && go.PrimaryScore >= 0.6) || (gi2 != null && gi2.PrimaryScore >= 0.6)) continue;
                        }
                        HsBar bar = new HsBar(); bar.Band = b; bar.Angle = a; bar.IsStart = isStart; bar.Strength = hitO + hitI;
                        res.Bars.Add(bar); outUsed[i] = true; inUsed[j] = true; break;
                    }
                }
            for (int i = 0; i < outRuns.Count; i++) if (!outUsed[i] && !NearBar(res, b, outRuns[i][0], 9 * s / pxPerDeg)) AddBase(bases, outRuns[i], 0, s, b, res);
            for (int j = 0; j < inRuns.Count; j++) if (!inUsed[j] && !NearBar(res, b, inRuns[j][0], 9 * s / pxPerDeg)) AddBase(bases, inRuns[j], 1, s, b, res);

            // a barb close to the ring can leave a narrow second run beside its own stroke: keep the wider
            {
                List<double[]> kept = new List<double[]>();
                foreach (double[] cand in bases)
                {
                    int clash = -1;
                    for (int q = 0; q < kept.Count; q++) if (kept[q][1] == cand[1] && Math.Abs(AngDiff(kept[q][0], cand[0])) * pxPerDeg < 18 * s) clash = q;
                    if (clash < 0) kept.Add(cand);
                    else if (cand[2] > kept[clash][2]) kept[clash] = cand;
                }
                bases = kept;
            }
            // 5. fit the glyph model at every base by overlap with the observed stroke component
            Claim = null;
            List<HsGlyphHit> hits = new List<HsGlyphHit>();
            foreach (double[] bs in bases)
            {
                HsGlyphHit g = FitGlyph(bs, b, R, cx, cy, s, pxPerDeg);
                if (g != null) hits.Add(g); else res.Unresolved.Add("band " + b + ": stroke at " + bs[0].ToString("0.0") + " deg could not be matched to any glyph");
            }
            // refine: each glyph is refitted with ink explained by its neighbours removed
            for (int round = 0; round < 3; round++)
            {
                if (round > 0)
                {
                    // a stroke fragment that belongs to a neighbouring glyph (e.g. a barb near the ring) is not a glyph
                    List<HsGlyphHit> keep = new List<HsGlyphHit>();
                    foreach (HsGlyphHit g in hits)
                    {
                        if (g.OwnFraction < 0.5 && g.PrimaryScore < 0.6) res.Unresolved.Add("band " + b + ": ignored stroke fragment at " + g.Angle.ToString("0.0") + " deg (part of a neighbouring glyph)");
                        else keep.Add(g);
                    }
                    hits = keep;
                }
                Claim = new int[W * H];
                foreach (HsGlyphHit g in hits) foreach (int pi in g.Pixels) Claim[pi]++;
                for (int i = 0; i < hits.Count; i++)
                {
                    foreach (int pi in hits[i].Pixels) Claim[pi]--;
                    HsGlyphHit g2 = FitGlyph(hits[i].Base, b, R, cx, cy, s, pxPerDeg);
                    if (g2 != null) hits[i] = g2;
                    foreach (int pi in hits[i].Pixels) Claim[pi]++;
                }
            }
            Claim = null;
            foreach (HsGlyphHit g in hits)
            {
                g.Pixels = null;
                // a stroke fragment that belongs to a neighbouring glyph (e.g. a barb near the ring) is not a glyph
                res.Glyphs.Add(g);
            }
        }
        res.Ok = true;
        return res;
    }

    // ---- model fitting -------------------------------------------------
    static double[] TaperPoly(double[] X, double[] Y, double w0, double swell)
    {
        int n = X.Length; double[] p = new double[4 * n];
        for (int i = 0; i < n; i++)
        {
            int i0 = Math.Max(0, i - 1), i1 = Math.Min(n - 1, i + 1);
            double dx = X[i1] - X[i0], dy = Y[i1] - Y[i0], m = Math.Sqrt(dx * dx + dy * dy); if (m == 0) m = 1;
            double nx = -dy / m, ny = dx / m, t = i / (n - 1.0);
            double ww = w0 * Math.Pow(1 - t, 0.9) * (1 + swell * Math.Sin(Math.PI * t));
            p[2 * i] = X[i] + nx * ww / 2; p[2 * i + 1] = Y[i] + ny * ww / 2;
            p[2 * (2 * n - 1 - i)] = X[i] - nx * ww / 2; p[2 * (2 * n - 1 - i) + 1] = Y[i] - ny * ww / 2;
        }
        return p;
    }

    static int[] stamp; static bool[] obs; static int wx0, wy0, wwid, whei, stampId;
    static int[] Claim; static List<int> Collect; static double[] lastCov;
    static double fcx, fcy, fR, fBand;

    static void FillCount(double[] p, ref int P, ref int I)
    {
        int n = p.Length / 2; double minY = 1e9, maxY = -1e9;
        for (int i = 0; i < n; i++) { if (p[2 * i + 1] < minY) minY = p[2 * i + 1]; if (p[2 * i + 1] > maxY) maxY = p[2 * i + 1]; }
        int y0 = Math.Max(wy0, (int)Math.Ceiling(minY - 0.5)), y1 = Math.Min(wy0 + whei - 1, (int)Math.Floor(maxY - 0.5));
        List<double> xs = new List<double>();
        for (int y = y0; y <= y1; y++)
        {
            double sy = y + 0.0; xs.Clear();
            for (int i = 0; i < n; i++)
            {
                int j = (i + 1) % n; double ay = p[2 * i + 1], by = p[2 * j + 1];
                if ((ay <= sy && by > sy) || (by <= sy && ay > sy)) xs.Add(p[2 * i] + (sy - ay) / (by - ay) * (p[2 * j] - p[2 * i]));
            }
            xs.Sort();
            for (int k = 0; k + 1 < xs.Count; k += 2)
            {
                int xa = Math.Max(wx0, (int)Math.Ceiling(xs[k])), xb = Math.Min(wx0 + wwid - 1, (int)Math.Floor(xs[k + 1]));
                for (int x = xa; x <= xb; x++)
                {
                    int li = (y - wy0) * wwid + (x - wx0);
                    if (stamp[li] == stampId) continue;
                    stamp[li] = stampId;
                    if (Collect != null) { Collect.Add(y * W + x); continue; }
                    if (Claim != null && Claim[y * W + x] > 0) continue;
                    double ddx = x - fcx, ddy = y - fcy; if (Math.Abs(Math.Sqrt(ddx * ddx + ddy * ddy) - fR) < fBand) continue;
                    P++; if (obs[li]) I++;
                }
            }
        }
    }

    static HsGlyphHit FitGlyph(double[] bs, int band, double R, double cx, double cy, double s, double pxPerDeg)
    {
        int d = (int)bs[1];
        double reach = (Len[2] + BarbLen + 14) * s;
        double bx0, by0; Pt(cx, cy, R, bs[0], out bx0, out by0);
        wx0 = Math.Max(0, (int)(bx0 - reach)); wy0 = Math.Max(0, (int)(by0 - reach));
        wwid = Math.Min(W, (int)(bx0 + reach)) - wx0; whei = Math.Min(H, (int)(by0 + reach)) - wy0;
        if (wwid < 10 || whei < 10) return null;
        fcx = cx; fcy = cy; fR = R; fBand = 10 * s;
        // observed: connected stroke component outside the ring band, seeded at the base row
        obs = new bool[wwid * whei]; stamp = new int[wwid * whei]; stampId = 0;
        double sxp, syp; Pt(cx, cy, R + (d == 0 ? 13 : -13) * s, bs[0], out sxp, out syp);
        int seedX = -1, seedY = -1; double bd = 1e9;
        for (int yy = (int)syp - 4; yy <= (int)syp + 4; yy++) for (int xx = (int)sxp - 4; xx <= (int)sxp + 4; xx++)
                if (xx >= 0 && yy >= 0 && xx < W && yy < H && M[yy * W + xx]) { double dd = (xx - sxp) * (xx - sxp) + (yy - syp) * (yy - syp); if (dd < bd) { bd = dd; seedX = xx; seedY = yy; } }
        if (seedX < 0) return null;
        int O = 0; Queue<int> qu = new Queue<int>(); int sl = (seedY - wy0) * wwid + (seedX - wx0); obs[sl] = true; qu.Enqueue(sl);
        while (qu.Count > 0)
        {
            int li = qu.Dequeue(); int lx = li % wwid, ly = li / wwid;
            if (Claim == null || Claim[(ly + wy0) * W + (lx + wx0)] == 0) O++;
            for (int k = 0; k < 4; k++)
            {
                int nx = lx + (k == 0 ? 1 : k == 1 ? -1 : 0), ny = ly + (k == 2 ? 1 : k == 3 ? -1 : 0);
                if (nx < 0 || ny < 0 || nx >= wwid || ny >= whei) continue;
                int ni = ny * wwid + nx; if (obs[ni]) continue;
                int gx = nx + wx0, gy = ny + wy0; if (!M[gy * W + gx]) continue;
                double ddx = gx - cx, ddy = gy - cy; if (Math.Abs(Math.Sqrt(ddx * ddx + ddy * ddy) - R) < fBand) continue;
                obs[ni] = true; qu.Enqueue(ni);
            }
        }
        if (O < 8) return null;
        int Otot = 0; for (int q = 0; q < obs.Length; q++) if (obs[q]) Otot++;
        double[] X = new double[NPri], Y = new double[NPri], BX = new double[NBarb], BY = new double[NBarb];
        double[] bestByVal = new double[36]; for (int k = 0; k < 36; k++) bestByVal[k] = -1;
        double best = -1, bestDel = 0; int bestV = -1;
        for (int pass = 0; pass < 2; pass++)
        {
            double lo = pass == 0 ? -8 : bestDel - 1.5, hi = pass == 0 ? 8 : bestDel + 1.5, st = pass == 0 ? 2 : 0.5;
            for (int c = 0; c < 2; c++) for (int l = 0; l < 3; l++) for (int bb = 0; bb < 3; bb++)
                    {
                        if (pass == 1 && (18 * d + 9 * c + 3 * bb + l) != bestV) continue;
                        for (double del = lo; del <= hi + 0.001; del += st)
                        {
                            double th = bs[0] + del * s / pxPerDeg, x0, y0; Pt(cx, cy, R, th, out x0, out y0);
                            Centerline(x0, y0, th, d, c, Len[l] * s, X, Y);
                            stampId++; int P = 0, I = 0;
                            FillCount(TaperPoly(X, Y, PriW * s, 0.35), ref P, ref I);
                            int side = c == 0 ? -1 : 1;
                            int[] ks = bb == 0 ? new int[0] : bb == 1 ? new int[] { 11 } : new int[] { 7, 14 };
                            foreach (int k in ks) { Barb(X, Y, k, side, s, BX, BY); FillCount(TaperPoly(BX, BY, BarbW * s, 0.1), ref P, ref I); }
                            double iou = (double)I / (P + O - I);
                            int v = 18 * d + 9 * c + 3 * bb + l;
                            if (iou > bestByVal[v]) bestByVal[v] = iou;
                            if (iou > best) { best = iou; bestV = v; bestDel = del; }
                        }
                    }
        }
        double second = 0; for (int k = 0; k < 36; k++) if (k != bestV && bestByVal[k] > second) second = bestByVal[k];
        // barb count: measure each candidate barb position on pixels outside the main stroke
        double barbMargin = 1;
        {
            int c3 = (bestV % 18) / 9, l3 = bestV % 3;
            double th = bs[0] + bestDel * s / pxPerDeg, x0, y0; Pt(cx, cy, R, th, out x0, out y0);
            Centerline(x0, y0, th, d, c3, Len[l3] * s, X, Y);
            Collect = new List<int>(); stampId++; int pp = 0, ii = 0;
            FillCount(TaperPoly(X, Y, PriW * s + 3 * s, 0.35), ref pp, ref ii);
            Dictionary<int, bool> prim = new Dictionary<int, bool>(); foreach (int pi2 in Collect) prim[pi2] = true;
            int side3 = c3 == 0 ? -1 : 1; int[] kk = new int[] { 7, 11, 14 }; double[] cov = new double[3];
            for (int q0 = 0; q0 < 9; q0++)
            {
                int q = q0 / 3, kpos = kk[q] + (q0 % 3) - 1;
                Barb(X, Y, kpos, side3, s, BX, BY);
                Collect = new List<int>(); stampId++;
                FillCount(TaperPoly(BX, BY, BarbW * s, 0.1), ref pp, ref ii);
                int tot = 0, hit = 0, totAll = 0, hitAll = 0;
                foreach (int gi in Collect)
                {
                    if (prim.ContainsKey(gi)) continue;
                    totAll++; if (M[gi]) hitAll++;
                    if (Claim != null && (Claim[gi] > 0 || (gi + 1 < W * H && Claim[gi + 1] > 0) || (gi >= 1 && Claim[gi - 1] > 0) || (gi + W < W * H && Claim[gi + W] > 0) || (gi >= W && Claim[gi - W] > 0))) continue;
                    tot++; if (M[gi]) hit++;
                }
                // if neighbours' strokes hide most of this barb position, judge it on all its pixels
                double cv = (tot < 0.12 * totAll || tot == 0) ? 0.35 : (double)hit / tot;
                if (q0 % 3 == 0 || cv > cov[q]) cov[q] = cv;
            }
            Collect = null;
            // presence threshold 0.35; the pattern decides the count
            double T = 0.35; double[] sB = new double[3];
            sB[0] = Math.Min(Math.Min(T - cov[0], T - cov[1]), T - cov[2]);
            sB[1] = Math.Min(cov[1] - T, cov[1] - Math.Max(cov[0], cov[2]));
            sB[2] = Math.Min(Math.Min(cov[0] - T, cov[2] - T), Math.Min(cov[0], cov[2]) - cov[1]);
            int bbest = 0; for (int q = 1; q < 3; q++) if (sB[q] > sB[bbest]) bbest = q;
            double bsec = -1; for (int q = 0; q < 3; q++) if (q != bbest && sB[q] > bsec) bsec = sB[q];
            barbMargin = sB[bbest] - bsec; lastCov = cov;
            int newV = 18 * d + 9 * c3 + 3 * bbest + l3;
            if (newV != bestV) { bestV = newV; }
        }
        HsGlyphHit g = new HsGlyphHit();
        {
            int c2 = (bestV % 18) / 9, b2 = (bestV % 9) / 3, l2 = bestV % 3;
            double th = bs[0] + bestDel * s / pxPerDeg, x0, y0; Pt(cx, cy, R, th, out x0, out y0);
            Centerline(x0, y0, th, d, c2, Len[l2] * s, X, Y);
            Collect = new List<int>(); stampId++; int P0 = 0, I0 = 0;
            FillCount(TaperPoly(X, Y, PriW * s, 0.35), ref P0, ref I0);
            int side2 = c2 == 0 ? -1 : 1;
            int[] ks2 = b2 == 0 ? new int[0] : b2 == 1 ? new int[] { 11 } : new int[] { 7, 14 };
            foreach (int k in ks2) { Barb(X, Y, k, side2, s, BX, BY); FillCount(TaperPoly(BX, BY, BarbW * s, 0.1), ref P0, ref I0); }
            g.Pixels = Collect; Collect = null;
        }
        g.Base = bs; g.OwnFraction = (double)O / Math.Max(1, Otot);
        g.Band = band; g.Angle = Norm(bs[0] + bestDel * s / pxPerDeg); g.Value = bestV; g.D = d;
        g.C = (bestV % 18) / 9; g.B = (bestV % 9) / 3; g.L = bestV % 3;
        g.PrimaryScore = best; g.BarbScore = best;
        g.BarbMargin = barbMargin; g.BarbCov = lastCov;
        double pm = 1; { int cb = (bestV % 18) / 9, lb = bestV % 3; double alt = 0; for (int k = 0; k < 36; k++) { if (k / 18 != d) continue; if ((k % 18) / 9 == cb && k % 3 == lb) continue; if (bestByVal[k] > alt) alt = bestByVal[k]; } double own = 0; for (int bb2 = 0; bb2 < 3; bb2++) { int kv = 18 * d + 9 * cb + 3 * bb2 + lb; if (bestByVal[kv] > own) own = bestByVal[kv]; } pm = own - alt; g.PrimaryMargin = pm; }
        g.Confidence = Math.Min(1, best / 0.6) * Math.Min(1, Math.Max(0, pm) / 0.08) * Math.Min(1, Math.Max(0, barbMargin + 0.1) / 0.3);
        return g;
    }

    static bool NearBar(HsRasterResult res, int band, double ang, double tolDeg)
    {
        foreach (HsBar br in res.Bars) if (br.Band == band && Math.Abs(AngDiff(br.Angle, ang)) < tolDeg) return true;
        return false;
    }

    static void AddBase(List<double[]> bases, double[] run, int dir, double s, int band, HsRasterResult res)
    {
        if (run[1] < 2.5 * s) return;
        if (run[1] > 28 * s) { res.Unresolved.Add("band " + band + ": ink mass " + run[1].ToString("0") + "px wide at " + run[0].ToString("0.0") + " deg is not a single glyph base"); return; }
        bases.Add(new double[] { run[0], dir, run[1] });
    }

    static List<double[]> Runs(bool[] row, double da, double R)
    {
        List<double[]> runs = new List<double[]>(); int n = row.Length;
        int startIdx = -1; for (int i = 0; i < n; i++) if (!row[i]) { startIdx = i; break; }
        if (startIdx < 0) return runs;
        int len = 0, first = -1;
        for (int k = 1; k <= n; k++)
        {
            int i = (startIdx + k) % n;
            if (row[i]) { if (len == 0) first = k; len++; }
            if ((!row[i] || k == n) && len > 0)
            {
                double mid = (startIdx + first + (len - 1) / 2.0) * da;
                runs.Add(new double[] { Norm(mid), len * da * Math.PI * R / 180.0 });
                len = 0;
            }
        }
        return runs;
    }
    static double Norm(double a) { a = a % 360.0; if (a < 0) a += 360.0; return a; }
    static double AngDiff(double a, double b) { double d = Norm(a - b); if (d > 180) d -= 360; return d; }
    static double AngMid(double a, double b) { return Norm(b + AngDiff(a, b) / 2.0); }
    // Synthetic raster of structural polygons (even-odd fill per polygon, 2x2 supersampled).
    // Used by the server self-test to exercise the raster pipeline without a browser.
    public static byte[] RenderPolygons(List<double[]> polys, int w, int h, double scale, bool darkBg, int seed)
    {
        int W2 = w * 2, H2 = h * 2; bool[] hi = new bool[W2 * H2];
        List<double> xs = new List<double>();
        foreach (double[] p in polys)
        {
            int n = p.Length / 2; double minY = 1e9, maxY = -1e9;
            for (int i = 0; i < n; i++) { double yy = p[2 * i + 1] * scale * 2; if (yy < minY) minY = yy; if (yy > maxY) maxY = yy; }
            int y0 = Math.Max(0, (int)Math.Floor(minY)), y1 = Math.Min(H2 - 1, (int)Math.Ceiling(maxY));
            for (int y = y0; y <= y1; y++)
            {
                double sy = y + 0.5; xs.Clear();
                for (int i = 0; i < n; i++)
                {
                    int j = (i + 1) % n;
                    double ax = p[2 * i] * scale * 2, ay = p[2 * i + 1] * scale * 2, bx = p[2 * j] * scale * 2, by = p[2 * j + 1] * scale * 2;
                    if ((ay <= sy && by > sy) || (by <= sy && ay > sy)) xs.Add(ax + (sy - ay) / (by - ay) * (bx - ax));
                }
                xs.Sort();
                for (int k = 0; k + 1 < xs.Count; k += 2)
                {
                    int xa = Math.Max(0, (int)Math.Ceiling(xs[k] - 0.5)), xb = Math.Min(W2 - 1, (int)Math.Floor(xs[k + 1] - 0.5));
                    for (int x = xa; x <= xb; x++) hi[y * W2 + x] = true;
                }
            }
        }
        byte[] g = new byte[w * h]; Random rnd = new Random(seed);
        double bg = darkBg ? 12 : 236, ink = darkBg ? 240 : 22;
        for (int y = 0; y < h; y++) for (int x = 0; x < w; x++)
            {
                int c = 0; if (hi[(2 * y) * W2 + 2 * x]) c++; if (hi[(2 * y) * W2 + 2 * x + 1]) c++; if (hi[(2 * y + 1) * W2 + 2 * x]) c++; if (hi[(2 * y + 1) * W2 + 2 * x + 1]) c++;
                double v = bg + (ink - bg) * c / 4.0 + (rnd.NextDouble() - 0.5) * 30;
                if (rnd.NextDouble() < 0.002) v = bg + (ink - bg) * 0.5;
                g[y * w + x] = (byte)Math.Max(0, Math.Min(255, v));
            }
        return g;
    }
}
