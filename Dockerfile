# Lehky PowerShell image (~140 MB) - LTS varianta na Alpine Linuxu
FROM mcr.microsoft.com/powershell:lts-alpine-3.20

WORKDIR /app

# Kod aplikace - vse co je staticke
COPY dashboard_server.ps1 medevio-dashboard-live.html plan-templates.json ./

# Default env pro kontejner
# DATA_DIR  = mountpoint pro persistentni soubory (clinics.json, plans.json)
# HOST = "+" znamena vsechny interfaces (potreba ve Fly za load balancerem)
# PORT = na cem posloucha HttpListener (Fly forwarduje 80/443 -> tento port)
ENV DATA_DIR=/data
ENV HOST=+
ENV PORT=8766
ENV TZ=Europe/Prague

EXPOSE 8766

CMD ["pwsh", "-NoProfile", "-File", "/app/dashboard_server.ps1"]
