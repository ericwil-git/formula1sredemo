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

    return {
        renderLineChart: renderLineChart,
        renderBarChart: renderBarChart,
        destroy: destroy
    };
})();
