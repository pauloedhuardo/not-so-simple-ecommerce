#!/bin/bash
# Sincroniza as senhas de Postgres e Mongo com o AWS Secrets Manager.
#
# O cluster Aurora e o DocumentDB usam manage_master_user_password = true
# (nsse-iac/serverless/variables.tf), entao quem gera e e dono das senhas do
# nsseAdmin e do nsse e a AWS. Todo terraform apply que recria um cluster gera
# senha nova e invalida o que estiver gravado, e o identity passa a responder
# 500 com "28P01: password ... is wrong". Rode este script depois de cada apply
# que mexa nos clusters.
#
# As duas connection strings tem formatos diferentes e nao aceitam o mesmo
# tratamento:
#   - Postgres e ADO.NET (pares separados por ';'), senha vai crua;
#   - Mongo e URI, entao a senha PRECISA ser percent-encoded. Sem isso um '#'
#     corta a URI num fragmento e um '[' faz o parser ler a senha como literal
#     IPv6 -- o erro estoura no new MongoUrl(...) antes de abrir socket, e
#     parece problema de rede quando e sintaxe.
#
# Uso:
#   ./cli/sync-db-secret.sh                       # so atualiza o .env
#   ./cli/sync-db-secret.sh --restart             # atualiza, recria os containers e recarrega o nginx
#   ./cli/sync-db-secret.sh --configmap [arquivo] # tambem atualiza o config-map do gitops

set -euo pipefail

rootPath="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
envFile="$rootPath/.env"
defaultConfigMap="$rootPath/../nsse-gitops/production/infraestructure/config-map.yml"
restart=false
configMapFile=""

while [ $# -gt 0 ]; do
    case "$1" in
        --restart)
            restart=true
            shift
            ;;
        --configmap)
            # aceita caminho opcional logo depois da flag
            if [ -n "${2:-}" ] && [ "${2#--}" = "$2" ]; then
                configMapFile="$2"
                shift 2
            else
                configMapFile="$defaultConfigMap"
                shift
            fi
            ;;
        *)
            echo "ERRO: argumento desconhecido '$1'"
            exit 1
            ;;
    esac
done

function checkDependencies(){

    for cmd in aws python3; do
        if ! command -v "$cmd" > /dev/null; then
            echo "ERRO: '$cmd' nao encontrado no PATH"
            exit 1
        fi
    done

    if [ ! -f "$envFile" ]; then
        echo "ERRO: $envFile nao existe"
        exit 1
    fi

    if [ -n "$configMapFile" ] && [ ! -f "$configMapFile" ]; then
        echo "ERRO: config-map '$configMapFile' nao existe"
        exit 1
    fi

    if ! aws sts get-caller-identity > /dev/null 2>&1; then
        echo "ERRO: credenciais AWS invalidas ou ausentes"
        exit 1
    fi
}

function resolveRegion(){

    # a regiao do .env manda; senao cai no perfil da AWS CLI, senao us-east-1
    region="$(grep -E '^AWS_REGION=' "$envFile" | tail -1 | cut -d= -f2- | tr -d '"'"'"' ')"
    [ -z "$region" ] && region="$(aws configure get region 2>/dev/null || true)"
    [ -z "$region" ] && region="us-east-1"
    echo "Regiao: $region"
}

function resolvePostgresSecretArn(){

    # o RDS Proxy e quem valida a conexao do cliente, entao o secret dele e a
    # fonte de verdade. Sem proxy, cai para o secret do proprio cluster.
    postgresSecretArn="$(aws rds describe-db-proxies \
        --region "$region" \
        --query 'DBProxies[0].Auth[0].SecretArn' \
        --output text 2>/dev/null || true)"

    if [ -z "$postgresSecretArn" ] || [ "$postgresSecretArn" = "None" ]; then
        echo "Nenhum RDS Proxy encontrado, usando o secret do cluster..."
        postgresSecretArn="$(aws rds describe-db-clusters \
            --region "$region" \
            --query "DBClusters[?Engine=='aurora-postgresql'].MasterUserSecret.SecretArn | [0]" \
            --output text)"
    fi

    if [ -z "$postgresSecretArn" ] || [ "$postgresSecretArn" = "None" ]; then
        echo "ERRO: nenhum secret de master user do Postgres encontrado em $region"
        exit 1
    fi

    echo "Secret Postgres: ...${postgresSecretArn: -24}"
}

function resolveMongoSecretArn(){

    # o DocumentDB nao tem proxy, entao a fonte de verdade e o secret do cluster
    mongoSecretArn="$(aws rds describe-db-clusters \
        --region "$region" \
        --query "DBClusters[?Engine=='docdb'].MasterUserSecret.SecretArn | [0]" \
        --output text 2>/dev/null || true)"

    if [ -z "$mongoSecretArn" ] || [ "$mongoSecretArn" = "None" ]; then
        echo "ERRO: nenhum secret de master user do DocumentDB encontrado em $region"
        exit 1
    fi

    echo "Secret Mongo:    ...${mongoSecretArn: -24}"
}

function fetchSecret(){

    aws secretsmanager get-secret-value \
        --region "$region" \
        --secret-id "$1" \
        --query SecretString \
        --output text
}

function updateFiles(){

    # o python cuida do parse do JSON e da reescrita: as senhas nunca passam por
    # variavel de shell exposta nem sao ecoadas.
    PG_SECRET="$(fetchSecret "$postgresSecretArn")" \
    MONGO_SECRET="$(fetchSecret "$mongoSecretArn")" \
    ENV_FILE="$envFile" \
    CONFIGMAP_FILE="$configMapFile" \
    python3 <<'PY'
import json, os, re, sys, urllib.parse

pg = json.loads(os.environ["PG_SECRET"])
mongo = json.loads(os.environ["MONGO_SECRET"])

# Mongo e URI: percent-encode obrigatorio. quote(safe='') cobre o conjunto
# reservado (: / ? # [ ] @ %) e de quebra remove o '$', o que dispensa o
# escape de interpolacao do docker compose nessa linha.
mongoUser = urllib.parse.quote(mongo["username"], safe="")
mongoPwd = urllib.parse.quote(mongo["password"], safe="")


def patch(path, rules, label):
    text = open(path, encoding="utf-8").read()
    original = text
    for pattern, repl, desc in rules:
        # re.M porque os padroes ancoram em '^' de linha, nao do arquivo;
        # '.' nao cruza newline, entao cada regra fica presa a sua linha.
        text, n = re.subn(pattern, repl, text, count=1, flags=re.M)
        if n != 1:
            sys.exit(f"ERRO: {desc} nao encontrada em {path}")
    open(path, "w", encoding="utf-8").write(text)
    print(f"  {label}: {'atualizado' if text != original else 'ja estava atualizado'}")


envPath = os.environ["ENV_FILE"]

# no .env o compose interpola '$', entao a senha do Postgres (que vai crua)
# precisa de '$$'. A do Mongo ja saiu percent-encoded e nao tem '$'.
pgEscaped = pg["password"].replace("$", "$$")

patch(envPath, [
    (r'(^CONNECTIONSTRINGS__DEFAULT=.*?)User ID=[^;]*',
     lambda m: f'{m.group(1)}User ID={pg["username"]}', "CONNECTIONSTRINGS__DEFAULT"),
    (r'(^CONNECTIONSTRINGS__DEFAULT=.*?)Password=[^;]*',
     lambda m: f'{m.group(1)}Password={pgEscaped}', "CONNECTIONSTRINGS__DEFAULT"),
    (r'(^CONNECTIONSTRINGS__MONGO="mongodb://)[^@]*(@)',
     lambda m: f'{m.group(1)}{mongoUser}:{mongoPwd}{m.group(2)}', "CONNECTIONSTRINGS__MONGO"),
], os.path.basename(envPath))

cmPath = os.environ.get("CONFIGMAP_FILE") or ""
if cmPath:
    patch(cmPath, [
        (r'(CONNECTIONSTRINGS__DEFAULT: .*?)User ID=[^;]*',
         lambda m: f'{m.group(1)}User ID={pg["username"]}', "CONNECTIONSTRINGS__DEFAULT"),
        (r'(CONNECTIONSTRINGS__DEFAULT: .*?)Password=[^;]*',
         lambda m: f'{m.group(1)}Password={pg["password"]}', "CONNECTIONSTRINGS__DEFAULT"),
        (r'(CONNECTIONSTRINGS__MONGO: "mongodb://)[^@]*(@)',
         lambda m: f'{m.group(1)}{mongoUser}:{mongoPwd}{m.group(2)}', "CONNECTIONSTRINGS__MONGO"),
    ], os.path.basename(cmPath))

print(f"  Postgres: usuario={pg['username']} senha={len(pg['password'])} chars"
      f" | escapou '$': {'$' in pg['password']}")
print(f"  Mongo:    usuario={mongo['username']} senha={len(mongo['password'])} chars"
      f" | encoding alterou: {mongoPwd != mongo['password']}")
PY
}

function restartServices(){

    if [ -n "$configMapFile" ]; then
        echo
        echo "config-map alterado: comite e faca push para o Argo sincronizar, e entao"
        echo "  kubectl -n nsse rollout restart deploy"
        echo "O rollout nao e opcional: o config-map entra por envFrom, que e lido uma"
        echo "unica vez no start do container -- pod ja rodando mantem a senha antiga."
    fi

    if [ "$restart" != true ]; then
        echo
        echo "Para aplicar local:  docker compose up -d && docker exec nsse.nginx.internal nginx -s reload"
        return
    fi

    echo
    echo "Recriando containers..."
    (cd "$rootPath" && docker compose up -d)

    # o recreate reembaralha os IPs dos containers e o nginx mantem os antigos
    # em cache, servindo 404/502 ate recarregar.
    echo "Recarregando nginx..."
    docker exec nsse.nginx.internal nginx -s reload
}

checkDependencies
resolveRegion
resolvePostgresSecretArn
resolveMongoSecretArn
updateFiles
restartServices
