using Plots, Measures, Statistics, Printf
import BenchmarkTools

# Visual style constants for the summary plot.
const SUMMARY_PLOT_RED   = RGB(0.85, 0.20, 0.20)
const SUMMARY_PLOT_GREEN = RGB(0.15, 0.60, 0.30)
const SUMMARY_PLOT_GREY  = RGB(0.55, 0.55, 0.55)

# How many outliers per side to show on the lollipop chart.
const SUMMARY_PLOT_MAX_PER_SIDE = 12
const SUMMARY_PLOT_MIN_PER_SIDE = 5

# Render a "spread of changes" plot for a comparison BenchmarkJob and write it
# to `dest_path` as a PNG. `judged` is the `BenchmarkGroup` of `TrialJudgement`
# values (`results["judged"]`). `title` is rendered above the plot.
#
# Returns true if the plot was written, false if there was nothing significant
# to show.
function write_summary_plot(dest_path::AbstractString,
                            judged::BenchmarkTools.BenchmarkGroup,
                            title::AbstractString)
    entries = BenchmarkTools.leaves(judged)
    sig = Tuple{String,Float64}[]
    for (ids, t) in entries
        if BenchmarkTools.isregression(t) || BenchmarkTools.isimprovement(t)
            r = BenchmarkTools.time(BenchmarkTools.ratio(t))
            (isfinite(r) && r > 0) || continue
            push!(sig, (_summary_plot_label(ids), Float64(r)))
        end
    end
    isempty(sig) && return false

    log2r = [log2(r) for (_, r) in sig]
    n_reg = count(>(0), log2r)
    n_imp = count(<(0), log2r)

    # Tukey's outlier rule on |log2(ratio)| selects the strongest changes.
    mags = abs.(log2r)
    fence = if length(mags) >= 4
        q1, q3 = quantile(mags, 0.25), quantile(mags, 0.75)
        q3 + 1.5 * (q3 - q1)
    else
        0.0
    end

    is_outlier(r) = abs(log2(r)) > fence
    regs_all = sort(filter(t -> t[2] > 1, sig); by = t -> -t[2])
    imps_all = sort(filter(t -> t[2] < 1, sig); by = t ->  t[2])
    select_side(side) = begin
        n = count(t -> is_outlier(t[2]), side)
        n = clamp(n, min(SUMMARY_PLOT_MIN_PER_SIDE, length(side)),
                  SUMMARY_PLOT_MAX_PER_SIDE)
        side[1:min(n, length(side))]
    end
    regs = select_side(regs_all)
    imps = select_side(imps_all)

    # Layout: fastest (smallest ratio) on top, slowest on bottom, with a
    # discontinuity gap between the two groups.
    GAP = 1.0
    nr, ni = length(regs), length(imps)
    y_regs = collect(1.0:nr)
    y_imps = collect((nr + 1 + GAP) .+ (1:ni) .- 1)
    combined = vcat(regs, reverse(imps))
    yvals    = vcat(y_regs, y_imps)
    xvals    = [log2(r) for (_, r) in combined]
    colors   = [r > 1 ? SUMMARY_PLOT_RED : SUMMARY_PLOT_GREEN for (_, r) in combined]
    ylabels  = [l for (l, _) in combined]
    y_gap_center = nr + 0.5 + GAP / 2

    xpad = 0.45
    xlims_top = (minimum(xvals) - xpad, maximum(xvals) + xpad)
    xticks_pos = [-1, -0.5, 0, 0.5, 1, 1.5, 2, 2.5, 3]
    xticks_lab = [@sprintf("%.2g×", 2.0^t) for t in xticks_pos]

    plot_height = max(460, 180 + (nr + ni) * 18)

    plt = plot(;
        size = (900, plot_height),
        framestyle = :zerolines,
        grid = :all,
        gridalpha = 0.3,
        gridstyle = :dot,
        legend = false,
        xlabel = "time ratio",
        title = title,
        titlefontsize = 10,
        yticks = false,
        xtickfontsize = 8,
        xguidefontsize = 8,
        xlims = xlims_top,
        ylims = (-3.0, maximum(yvals) + 1.4),
        xticks = (xticks_pos, xticks_lab),
        left_margin = 4mm,
        right_margin = 4mm,
        bottom_margin = 4mm,
        background_color = :white,
    )

    # Lollipops.
    for (y, x, c) in zip(yvals, xvals, colors)
        plot!(plt, [0, x], [y, y]; color = c, linewidth = 2.5)
    end
    scatter!(plt, xvals, yvals; markercolor = colors, markerstrokewidth = 0,
             markersize = 5)

    # Row labels on the opposite side of x=0 from each lollipop.
    for (y, x, lab) in zip(yvals, xvals, ylabels)
        if x > 0
            annotate!(plt, [(-0.05, y, text(lab, 7, :right, :vcenter, :black))])
        else
            annotate!(plt, [( 0.05, y, text(lab, 7, :left,  :vcenter, :black))])
        end
    end

    # Directional cue above the top row, straddling 1×.
    let ytop = maximum(yvals) + 0.7
        annotate!(plt, [(-0.05, ytop, text("← faster", 8, :right, :vcenter, SUMMARY_PLOT_GREEN))])
        annotate!(plt, [( 0.05, ytop, text("slower →", 8, :left,  :vcenter, SUMMARY_PLOT_RED))])
    end

    # Per-row ratio label past the dot.
    for (y, x, (_, r)) in zip(yvals, xvals, combined)
        if r >= 1
            annotate!(plt, [(x + 0.05, y, text(@sprintf("%.2f×", r), 7, :left, :vcenter, :black))])
        else
            annotate!(plt, [(x - 0.05, y, text(@sprintf("%.2f×", r), 7, :right, :vcenter, :black))])
        end
    end

    # Axis-break discontinuity drawn on the 1× line between the two groups.
    let half_h = 0.30, half_w = 0.045, yc = y_gap_center
        plot!(plt, Shape([-half_w, half_w, half_w, -half_w],
                         [yc - half_h, yc - half_h, yc + half_h, yc + half_h]);
              color = :white, linecolor = :white, linewidth = 0)
        for dy in (-0.08, 0.08)
            plot!(plt, [-half_w, half_w],
                  [yc + dy - half_h*0.6, yc + dy + half_h*0.6];
                  color = :black, linewidth = 1.0)
        end
    end

    # Embedded histogram strip showing the spread of all significant changes.
    let
        edges = range(min(-1.2, minimum(log2r) - 0.1),
                      max(3.0, maximum(log2r) + 0.1); length = 49)
        h_imp = [count(v -> edges[i] <= v < edges[i+1] && v < 0, log2r)
                 for i in 1:length(edges)-1]
        h_reg = [count(v -> edges[i] <= v < edges[i+1] && v > 0, log2r)
                 for i in 1:length(edges)-1]
        centers = [(edges[i] + edges[i+1])/2 for i in 1:length(edges)-1]
        maxh = maximum(vcat(h_imp, h_reg))
        maxh == 0 && return true
        strip_top    = -0.4
        strip_height =  2.2
        scale = strip_height / maxh
        base = strip_top - strip_height
        for (c, ni_, nr_) in zip(centers, h_imp, h_reg)
            n = ni_ + nr_
            n == 0 && continue
            col = ni_ > 0 ? SUMMARY_PLOT_GREEN : SUMMARY_PLOT_RED
            plot!(plt, Shape([c - step(edges)/2, c + step(edges)/2,
                              c + step(edges)/2, c - step(edges)/2],
                             [base, base, base + n*scale, base + n*scale]);
                  color = col, linecolor = col, linewidth = 0, fillalpha = 0.85)
        end
        plot!(plt, [xlims_top[1], xlims_top[2]], [base, base];
              color = :black, linewidth = 0.5, linestyle = :dot)
        annotate!(plt, [(xlims_top[1] + 0.05, strip_top - 0.1,
                  text("all $(n_reg + n_imp) significant changes",
                       7, :left, :top, SUMMARY_PLOT_GREY))])
    end

    savefig(plt, dest_path)
    return true
end

# Compact label for a benchmark id vector, suitable for a plot row.
function _summary_plot_label(ids)
    parts = String[]
    for i in ids
        s = i isa Tuple ? join(string.(i), ",") : string(i)
        push!(parts, s)
    end
    return join(parts, " ▸ ")
end
