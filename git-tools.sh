#!/usr/bin/env bash

# git-hub.sh - Sistema de gerenciamento de repositórios GitHub
# Autor: Sistema de automação
# Uso: ./github-repos.sh [comando]

GITHUB_USER="$(grep user: ${HOME}/.config/hub | awk '{print $3}')"
DB_FILE="$HOME/.github_${GITHUB_USER}_repos.db"

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Função para inicializar o banco de dados
init_db() {
    if [ ! -f "$DB_FILE" ]; then
        echo -e "${BLUE}Criando banco de dados...${NC}"
        sqlite3 "$DB_FILE" <<EOF
CREATE TABLE IF NOT EXISTS repositories (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL UNIQUE,
    full_name TEXT NOT NULL,
    description TEXT,
    clone_url TEXT NOT NULL,
    ssh_url TEXT NOT NULL,
    html_url TEXT NOT NULL,
    language TEXT,
    stars INTEGER DEFAULT 0,
    forks INTEGER DEFAULT 0,
    updated_at TEXT,
    created_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_name ON repositories(name);
CREATE INDEX IF NOT EXISTS idx_language ON repositories(language);
EOF
        echo -e "${GREEN}Banco de dados criado com sucesso!${NC}"
    fi
}

# Função para popular o banco com todos os repositórios
populate_db() {
    echo -e "${BLUE}Buscando repositórios do usuário $GITHUB_USER...${NC}"

    # Limpa a tabela antes de popular
    sqlite3 "$DB_FILE" "DELETE FROM repositories;"

    page=1
    total_repos=0

    while true; do
        echo -e "${YELLOW}Processando página $page...${NC}"

        # Busca repositórios da API do GitHub (100 por página, máximo permitido)
        response=$(curl -s "https://api.github.com/users/$GITHUB_USER/repos?per_page=100&page=$page&sort=updated")

        # Verifica se retornou repositórios
        repo_count=$(echo "$response" | grep -o '"name":' | wc -l)

        if [ "$repo_count" -eq 0 ]; then
            break
        fi

        # Parse JSON e insere no banco
        echo "$response" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for repo in data:
    name = repo.get('name', '').replace(\"'\", \"''\")
    full_name = repo.get('full_name', '').replace(\"'\", \"''\")
    desc = repo.get('description', '') or ''
    desc = desc.replace(\"'\", \"''\")
    clone_url = repo.get('clone_url', '')
    ssh_url = repo.get('ssh_url', '')
    html_url = repo.get('html_url', '')
    language = repo.get('language', '') or 'N/A'
    stars = repo.get('stargazers_count', 0)
    forks = repo.get('forks_count', 0)
    updated = repo.get('updated_at', '')
    created = repo.get('created_at', '')

    print(f\"INSERT OR REPLACE INTO repositories (name, full_name, description, clone_url, ssh_url, html_url, language, stars, forks, updated_at, created_at) VALUES ('{name}', '{full_name}', '{desc}', '{clone_url}', '{ssh_url}', '{html_url}', '{language}', {stars}, {forks}, '{updated}', '{created}');\")
" | sqlite3 "$DB_FILE"

        total_repos=$((total_repos + repo_count))
        echo -e "${GREEN}✓ $repo_count repositórios processados (Total: $total_repos)${NC}"

        # Se retornou menos de 100, é a última página
        if [ "$repo_count" -lt 100 ]; then
            break
        fi

        page=$((page + 1))
        sleep 1 # Evita rate limit
    done

    echo -e "${GREEN}✓ Total de $total_repos repositórios salvos no banco!${NC}"
}

# Função para buscar repositórios
search_repos() {
    local query="$1"

    if [ -z "$query" ]; then
        echo -e "${RED}Erro: Informe um termo de busca${NC}"
        echo "Uso: $0 search <termo>"
        return 1
    fi

    echo -e "${BLUE}Buscando por: '$query'${NC}"
    echo ""

    results=$(sqlite3 "$DB_FILE" "
        SELECT name, description, language, stars, clone_url, ssh_url
        FROM repositories
        WHERE name LIKE '%${query}%'
           OR description LIKE '%${query}%'
           OR language LIKE '%${query}%'
        ORDER BY stars DESC, name ASC;
    ")

    if [ -z "$results" ]; then
        echo -e "${YELLOW}Nenhum repositório encontrado.${NC}"
        return 0
    fi

    count=0
    echo "$results" | while IFS='|' read -r name desc lang stars clone_url ssh_url; do
        count=$((count + 1))
        echo -e "${GREEN}[$count] $name${NC}"
        [ -n "$desc" ] && echo -e "    Descrição: $desc"
        echo -e "    Linguagem: $lang | ⭐ $stars"
        echo -e "    ${BLUE}HTTPS:${NC} $clone_url"
        echo -e "    ${BLUE}SSH:${NC}   $ssh_url"
        echo ""
    done
}

# Função para listar todos os repositórios
list_all() {
    echo -e "${BLUE}Todos os repositórios:${NC}"
    echo ""

    sqlite3 "$DB_FILE" "
        SELECT name, language, stars, updated_at
        FROM repositories
        ORDER BY updated_at DESC;
    " | while IFS='|' read -r name lang stars updated; do
        printf "${GREEN}%-40s${NC} | %-15s | ⭐ %-3s | %s\n" "$name" "$lang" "$stars" "${updated:0:10}"
    done
}

# Função para gerar comando de clonagem
clone_cmd() {
    local query="$1"
    local protocol="${2:-https}" # https ou ssh

    if [ -z "$query" ]; then
        echo -e "${RED}Erro: Informe o nome do repositório${NC}"
        echo "Uso: $0 clone <nome> [https|ssh]"
        return 1
    fi

    if [ "$protocol" = "ssh" ]; then
        url=$(sqlite3 "$DB_FILE" "SELECT ssh_url FROM repositories WHERE name = '$query' LIMIT 1;")
    else
        url=$(sqlite3 "$DB_FILE" "SELECT clone_url FROM repositories WHERE name = '$query' LIMIT 1;")
    fi

    if [ -z "$url" ]; then
        echo -e "${RED}Repositório '$query' não encontrado.${NC}"
        echo -e "${YELLOW}Tente buscar com: $0 search $query${NC}"
        return 1
    fi

    echo -e "${GREEN}Comando de clonagem:${NC}"
    echo ""
    echo -e "${BLUE}git clone $url${NC}"
    echo ""
    echo -e "${YELLOW}Copie e execute o comando acima, ou execute diretamente:${NC}"
    echo "eval \"\$(./github-repos.sh clone-exec $query $protocol)\""
}

# Função para executar clonagem diretamente
clone_exec() {
    local query="$1"
    local protocol="${2:-https}"

    if [ "$protocol" = "ssh" ]; then
        url=$(sqlite3 "$DB_FILE" "SELECT ssh_url FROM repositories WHERE name = '$query' LIMIT 1;")
    else
        url=$(sqlite3 "$DB_FILE" "SELECT clone_url FROM repositories WHERE name = '$query' LIMIT 1;")
    fi

    if [ -z "$url" ]; then
        return 1
    fi

    echo "git clone $url"
}

# Função para mostrar estatísticas
stats() {
    echo -e "${BLUE}Estatísticas dos repositórios:${NC}"
    echo ""

    total=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM repositories;")
    echo -e "Total de repositórios: ${GREEN}$total${NC}"

    echo ""
    echo -e "${YELLOW}Top 5 linguagens:${NC}"
    sqlite3 "$DB_FILE" "
        SELECT language, COUNT(*) as count
        FROM repositories
        WHERE language != 'N/A'
        GROUP BY language
        ORDER BY count DESC
        LIMIT 5;
    " | while IFS='|' read -r lang count; do
        printf "  %-20s: %s\n" "$lang" "$count"
    done

    echo ""
    echo -e "${YELLOW}Top 5 mais estrelados:${NC}"
    sqlite3 "$DB_FILE" "
        SELECT name, stars
        FROM repositories
        ORDER BY stars DESC
        LIMIT 5;
    " | while IFS='|' read -r name stars; do
        printf "  ⭐ %-3s - %s\n" "$stars" "$name"
    done
}

# Menu de ajuda
show_help() {
    echo -e "${BLUE}Sistema de Gerenciamento de Repositórios GitHub${NC}"
    echo ""
    echo -e "${GREEN}Comandos disponíveis:${NC}"
    echo ""
    echo -e "  ${YELLOW}init${NC}           Inicializa o banco de dados"
    echo -e "  ${YELLOW}populate${NC}        Baixa todos os repositórios do GitHub e popula o banco"
    echo -e "  ${YELLOW}search <termo>${NC}  Busca repositórios por nome, descrição ou linguagem"
    echo -e "  ${YELLOW}list${NC}            Lista todos os repositórios"
    echo -e "  ${YELLOW}clone <nome>${NC}    Mostra comando para clonar repositório (HTTPS)"
    echo -e "  ${YELLOW}clone <nome> ssh${NC} Mostra comando para clonar repositório (SSH)"
    echo -e "  ${YELLOW}stats${NC}           Mostra estatísticas dos repositórios"
    echo -e "  ${YELLOW}help${NC}            Mostra esta ajuda"
    echo ""
    echo -e "${GREEN}Exemplos:${NC}"
    echo -e "  $0 populate                 # Popula o banco de dados"
    echo -e "  $0 search python            # Busca repos com \"python\""
    echo -e "  $0 clone meu-projeto        # Gera comando de clone"
    echo -e "  $0 clone meu-projeto ssh    # Gera comando de clone via SSH"
    echo ""
}

# Main
main() {
    # Verifica dependências
    command -v sqlite3 >/dev/null 2>&1 || {
        echo -e "${RED}Erro: sqlite3 não encontrado. Instale com: apt install sqlite3${NC}"
        exit 1
    }
    command -v curl >/dev/null 2>&1 || {
        echo -e "${RED}Erro: curl não encontrado. Instale com: apt install curl${NC}"
        exit 1
    }
    command -v python3 >/dev/null 2>&1 || {
        echo -e "${RED}Erro: python3 não encontrado. Instale com: apt install python3${NC}"
        exit 1
    }

    init_db

    case "${1:-help}" in
        init)
            echo "Banco de dados já inicializado em: $DB_FILE"
            ;;
        populate)
            populate_db
            ;;
        search)
            search_repos "$2"
            ;;
        list)
            list_all
            ;;
        clone)
            clone_cmd "$2" "$3"
            ;;
        clone-exec)
            clone_exec "$2" "$3"
            ;;
        stats)
            stats
            ;;
        help | --help | -h)
            show_help
            ;;
        *)
            echo -e "${RED}Comando inválido: $1${NC}"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

main "$@"
exit 0
