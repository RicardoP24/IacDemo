// Relative URL: the page is served under /<tenant>/, so this resolves to /<tenant>/api/info
fetch("api/info")
    .then((response) => {
        if (!response.ok) throw new Error(response.status);
        return response.json();
    })
    .then((info) => {
        document.getElementById("tenant").textContent = info.tenant;
        document.getElementById("version").textContent = info.version;
        document.getElementById("pod").textContent = info.pod;
    })
    .catch(() => {
        document.getElementById("error").hidden = false;
    });
