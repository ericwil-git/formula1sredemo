// charts.js — Chart.js interop helpers invoked from Blazor pages.
window.f1Charts = (function () {
    const charts = {};

    function destroy(id) {
        if (charts[id]) { charts[id].destroy(); delete charts[id]; }
    }

    function renderLineChart(canvasId, title, datasets, xLabel) {
        destroy(canvasId);
        const ctx = document.getElementById(canvasId);
        if (!ctx) return;
        charts[canvasId] = new Chart(ctx, {
            type: 'line',
            data: { datasets: datasets.map(d => ({
                label: d.label, data: d.points, borderColor: d.color,
                backgroundColor: d.color, borderWidth: 1.5,
                pointRadius: 0, tension: 0.1, parsing: false
            }))},
            options: {
                responsive: true, animation: false,
                plugins: { title: { display: !!title, text: title } },
                scales: {
                    x: { type: 'linear', title: { display: true, text: xLabel } },
                    y: { beginAtZero: false }
                }
            }
        });
    }

    function renderBarChart(canvasId, title, labels, values, color) {
        destroy(canvasId);
        const ctx = document.getElementById(canvasId);
        if (!ctx) return;
        charts[canvasId] = new Chart(ctx, {
            type: 'bar',
            data: { labels: labels, datasets: [{
                label: title, data: values, backgroundColor: color || '#f78166'
            }]},
            options: {
                responsive: true, animation: false,
                plugins: { legend: { display: false }, title: { display: true, text: title } },
                scales: { y: { beginAtZero: true } }
            }
        });
    }

    // -----------------------------------------------------------------
    // Categorical line chart (one line per driver, x-axis = labels[],
    // y-axis = numeric). Used for Q1 -> Q2 -> Q3 progression.
    // datasets: [{label, color, points: [number|null,...]}]
    // -----------------------------------------------------------------
    function renderCategoryLineChart(canvasId, title, labels, datasets, yLabel) {
        destroy(canvasId);
        const ctx = document.getElementById(canvasId);
        if (!ctx) return;
        charts[canvasId] = new Chart(ctx, {
            type: 'line',
            data: {
                labels: labels,
                datasets: datasets.map(d => ({
                    label: d.label,
                    data: d.points,
                    borderColor: d.color,
                    backgroundColor: d.color,
                    borderWidth: 1.5,
                    spanGaps: true,
                    pointRadius: 3
                }))
            },
            options: {
                responsive: true, animation: false,
                plugins: { title: { display: !!title, text: title } },
                scales: {
                    y: {
                        beginAtZero: false,
                        title: { display: !!yLabel, text: yLabel }
                    }
                }
            }
        });
    }

    // -----------------------------------------------------------------
    // Lap-time distribution per driver, rendered as a custom min/max +
    // IQR overlay using two stacked bar datasets:
    //   - "iqr" bar from Q1 to Q3 (interquartile box)
    //   - "median" point overlay
    // Plus thin lines for min/max whiskers via floating bars.
    //
    // stats: [{driver, min, q1, median, q3, max, color}]
    // -----------------------------------------------------------------
    function renderLapBoxChart(canvasId, title, stats, yLabel) {
        destroy(canvasId);
        const ctx = document.getElementById(canvasId);
        if (!ctx) return;

        const labels  = stats.map(s => s.driver);
        const whisker = stats.map(s => [s.min, s.max]);
        const box     = stats.map(s => [s.q1, s.q3]);
        const median  = stats.map(s => s.median);

        charts[canvasId] = new Chart(ctx, {
            type: 'bar',
            data: {
                labels: labels,
                datasets: [
                    {
                        type: 'bar',
                        label: 'min-max',
                        data: whisker,
                        backgroundColor: 'rgba(150,150,150,0.25)',
                        borderColor: 'rgba(150,150,150,0.6)',
                        borderWidth: 1,
                        barPercentage: 0.15,
                        categoryPercentage: 0.6
                    },
                    {
                        type: 'bar',
                        label: 'IQR (Q1-Q3)',
                        data: box,
                        backgroundColor: stats.map(s => s.color || '#58a6ff'),
                        borderColor: '#0d1117',
                        borderWidth: 1,
                        barPercentage: 0.7,
                        categoryPercentage: 0.6
                    },
                    {
                        type: 'line',
                        label: 'median',
                        data: median,
                        borderColor: '#fff',
                        backgroundColor: '#fff',
                        showLine: false,
                        pointRadius: 5,
                        pointStyle: 'rectRot'
                    }
                ]
            },
            options: {
                responsive: true, animation: false,
                plugins: { title: { display: !!title, text: title } },
                scales: {
                    y: {
                        beginAtZero: false,
                        title: { display: !!yLabel, text: yLabel }
                    }
                }
            }
        });
    }

    // -----------------------------------------------------------------
    // Tyre stint Gantt: one row per driver, horizontal floating bars
    // colored by compound. Uses the indexAxis:'y' bar trick.
    //
    // drivers:  ['VER','LEC',...]  (order = chart rows top-to-bottom)
    // stints:   [{driver, fromLap, toLap, compound}]
    // -----------------------------------------------------------------
    function renderTyreGantt(canvasId, title, drivers, stints) {
        destroy(canvasId);
        const ctx = document.getElementById(canvasId);
        if (!ctx) return;

        const compoundColors = {
            SOFT:         '#ff5d5d',
            MEDIUM:       '#ffd166',
            HARD:         '#e8e8e8',
            INTERMEDIATE: '#3fb950',
            WET:          '#58a6ff',
            UNKNOWN:      '#888'
        };

        // One dataset per compound so the legend stays useful.
        const compounds = [...new Set(stints.map(s => (s.compound || 'UNKNOWN').toUpperCase()))];
        const datasets = compounds.map(c => ({
            label: c,
            data: drivers.map(d => {
                // Find ALL stints for this driver+compound; floating bar
                // doesn't support multiple per category, so we emit the
                // first one and rely on multiple datasets across compounds
                // for repeat stints (good enough for a demo).
                const seg = stints.find(s => s.driver === d &&
                    (s.compound || 'UNKNOWN').toUpperCase() === c);
                return seg ? [seg.fromLap, seg.toLap] : null;
            }),
            backgroundColor: compoundColors[c] || '#888',
            borderColor: '#0d1117',
            borderWidth: 1,
            borderSkipped: false
        }));

        // Add additional datasets for second/third stints of the same compound.
        const counts = {};
        stints.forEach(s => {
            const k = s.driver + '|' + (s.compound || 'UNKNOWN').toUpperCase();
            counts[k] = (counts[k] || 0) + 1;
        });
        const maxRepeats = Math.max(1, ...Object.values(counts));
        for (let r = 1; r < maxRepeats; r++) {
            compounds.forEach(c => {
                datasets.push({
                    label: c + ' (#' + (r + 1) + ')',
                    data: drivers.map(d => {
                        const segs = stints.filter(s => s.driver === d &&
                            (s.compound || 'UNKNOWN').toUpperCase() === c);
                        return segs[r] ? [segs[r].fromLap, segs[r].toLap] : null;
                    }),
                    backgroundColor: compoundColors[c] || '#888',
                    borderColor: '#0d1117',
                    borderWidth: 1,
                    borderSkipped: false
                });
            });
        }

        charts[canvasId] = new Chart(ctx, {
            type: 'bar',
            data: { labels: drivers, datasets: datasets },
            options: {
                indexAxis: 'y',
                responsive: true, animation: false,
                plugins: {
                    title: { display: !!title, text: title },
                    legend: { labels: { filter: i => !i.text.includes('(#') } }
                },
                scales: {
                    x: { stacked: false, title: { display: true, text: 'Lap' } },
                    y: { stacked: true }
                }
            }
        });
    }

    return {
        renderLineChart: renderLineChart,
        renderBarChart: renderBarChart,
        renderCategoryLineChart: renderCategoryLineChart,
        renderLapBoxChart: renderLapBoxChart,
        renderTyreGantt: renderTyreGantt,
        destroy: destroy
    };
})();
