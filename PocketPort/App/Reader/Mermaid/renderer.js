async function renderDiagram(source, dark) {
    mermaid.initialize({
        startOnLoad: false,
        securityLevel: "strict",
        theme: dark ? "dark" : "default",
        themeCSS: "",
        fontFamily: "-apple-system, system-ui, sans-serif",
        htmlLabels: false,
        flowchart: { htmlLabels: false },
        suppressErrorRendering: true,
        maxTextSize: 50000,
        maxEdges: 500,
        secure: [
            "secure", "securityLevel", "startOnLoad", "theme", "themeCSS",
            "fontFamily", "htmlLabels", "flowchart", "dompurifyConfig",
            "suppressErrorRendering", "maxTextSize", "maxEdges"
        ]
    });

    let result;
    try {
        result = await mermaid.render("pocketport-diagram", source);
    } catch {
        return 0;
    }
    const container = document.getElementById("diagram");
    container.innerHTML = result.svg;
    const svg = container.querySelector("svg");
    const { width, height } = svg.viewBox.baseVal;
    if (!(width > 0 && height > 0)) throw new Error("Invalid diagram size");
    svg.style.maxWidth = "none";
    svg.style.width = width + "px";
    svg.style.height = height + "px";
    return Math.ceil(height + 24);
}
