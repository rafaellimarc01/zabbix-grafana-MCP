# Exceções aceitas do "trivy config" nos manifests do Kubernetes.
# Cada exceção vale só para o recurso citado: se outro container ou ConfigMap
# cair na mesma regra, o CI continua falhando.
package trivy

import rego.v1

default ignore := false

# KSV-0014 (readOnlyRootFilesystem): as imagens oficiais do Zabbix escrevem
# configuração e PID em /etc/zabbix, /var/lib/zabbix e /tmp no start. O
# PostgreSQL, o Grafana e o zabbix-init já rodam com o disco somente leitura.
ignore if {
	input.ID == "KSV-0014"
	some name in ["zabbix-agent", "zabbix-server", "zabbix-web"]
	startswith(input.Message, sprintf("Container '%s' of Deployment '%s'", [name, name]))
}

# KSV-0109 (segredo em ConfigMap): falso positivo. Os ConfigMaps só citam o
# nome das variáveis ($ZABBIX_PASSWORD, $ZABBIX_GRAFANA_PASSWORD...); os
# valores vêm do Secret zabbix-secrets.
ignore if {
	input.ID == "KSV-0109"
	some prefix in ["grafana-datasources-", "zabbix-init-script-"]
	startswith(input.Message, sprintf("ConfigMap '%s", [prefix]))
}
