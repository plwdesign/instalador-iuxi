#!/bin/bash

#######################################
# Instala o transcreveAPI para uma instância específica
# Arguments:
#   instancia_name - Nome da instância
#######################################
install_transcreve_api() {
  local instancia_name=$1
  
  print_banner
  printf "${YELLOW} 💻 Instalando transcreveAPI para a instância ${instancia_name}...${GRAY_LIGHT}"
  printf "\n\n"
  
  # Verificar se a instância existe
  if [ ! -d "/home/deploy/${instancia_name}" ]; then
    printf "${RED}❌ Instância ${instancia_name} não encontrada!${NC}\n"
    printf "${YELLOW}Pressione ENTER para continuar...${NC}\n"
    read -r
    return 1
  fi
  
  # Verificar se o backend existe
  if [ ! -d "/home/deploy/${instancia_name}/backend" ]; then
    printf "${RED}❌ Diretório backend não encontrado para a instância ${instancia_name}!${NC}\n"
    printf "${YELLOW}Pressione ENTER para continuar...${NC}\n"
    read -r
    return 1
  fi
  
  # Verificar se o backend está rodando (PM2) - executar como usuário deploy
  printf "${YELLOW}🔍 Verificando se o backend está rodando no PM2...${NC}\n"
  
  pm2_backend_status=$(sudo su - deploy -c "pm2 list --no-color 2>/dev/null | grep '${instancia_name}-backend' | head -1" 2>/dev/null)
  
  if [ -z "$pm2_backend_status" ]; then
    printf "${RED}❌ Backend da instância ${instancia_name} não está rodando no PM2!${NC}\n"
    printf "${YELLOW}Por favor, instale e inicie o Whaticket primeiro.${NC}\n"
    printf "${YELLOW}Pressione ENTER para continuar...${NC}\n"
    read -r
    return 1
  else
    printf "${GREEN}✓ Backend encontrado no PM2${NC}\n"
    # Verificar se está online
    pm2_status=$(echo "$pm2_backend_status" | awk '{print $10}')
    if [ "$pm2_status" != "online" ]; then
      printf "${YELLOW}⚠ Backend está no PM2 mas não está online (status: $pm2_status)${NC}\n"
      printf "${YELLOW}Deseja continuar mesmo assim? (s/N): ${NC}"
      read -r continue_anyway
      if [ "$continue_anyway" != "s" ] && [ "$continue_anyway" != "S" ]; then
        return 1
      fi
    fi
  fi
  
  sleep 2
  
  # Navegar para o diretório do transcreveAPI
  TRANSCREVE_DIR="/home/deploy/vipclub/transcreveAPI"
  
  if [ ! -d "$TRANSCREVE_DIR" ]; then
    printf "${RED}❌ Diretório do transcreveAPI não encontrado em ${TRANSCREVE_DIR}!${NC}\n"
    printf "${YELLOW}Verifique se o diretório existe.${NC}\n"
    printf "${YELLOW}Pressione ENTER para continuar...${NC}\n"
    read -r
    return 1
  fi
  
  cd "$TRANSCREVE_DIR"
  
  # Verificar se Docker está instalado
  if ! command -v docker &> /dev/null; then
    printf "${RED}❌ Docker não está instalado!${NC}\n"
    printf "${YELLOW}Instalando Docker...${NC}\n"
    
    sudo su - root <<EOF
    apt-get update -y
    apt-get install -y apt-transport-https ca-certificates curl software-properties-common
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
    add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu \$(lsb_release -cs) stable"
    apt-get update -y
    apt-get install -y docker-ce docker-compose-plugin
    systemctl start docker
    systemctl enable docker
    usermod -aG docker deploy
EOF
    
    printf "${GREEN}✓ Docker instalado com sucesso!${NC}\n"
    sleep 2
  fi
  
  # Verificar se docker compose está disponível
  if docker compose version &> /dev/null; then
    DOCKER_COMPOSE_CMD="docker compose"
  elif command -v docker-compose &> /dev/null; then
    DOCKER_COMPOSE_CMD="docker-compose"
  else
    printf "${YELLOW}Instalando Docker Compose...${NC}\n"
    sudo apt-get install -y docker-compose-plugin
    DOCKER_COMPOSE_CMD="docker compose"
  fi
  
  # Verificar permissões Docker
  if ! docker ps &> /dev/null; then
    printf "${YELLOW}Ajustando permissões Docker...${NC}\n"
    sudo usermod -aG docker deploy
    printf "${YELLOW}Você pode precisar fazer logout/login para usar Docker sem sudo.${NC}\n"
    DOCKER_CMD="sudo docker"
    DOCKER_COMPOSE_CMD="sudo $DOCKER_COMPOSE_CMD"
  else
    DOCKER_CMD="docker"
  fi
  
  # Detectar IP do servidor
  SERVER_IP=""
  if command -v ip &> /dev/null; then
    SERVER_IP=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K\S+' | head -1)
  fi
  if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(hostname -I | awk '{print $1}' 2>/dev/null)
  fi
  if [ -z "$SERVER_IP" ]; then
    SERVER_IP="127.0.0.1"
  fi
  
  printf "${GREEN}✓ IP do servidor detectado: ${SERVER_IP}${NC}\n"
  
  # Encontrar porta disponível
  printf "${YELLOW}🔍 Procurando porta disponível...${NC}\n"
  
  FOUND_PORT=""
  AVOID_PORTS=(22 25 80 443 3306 5432 6379 8080 3000 3001 3250 5000 8000 8081 9000)
  
  is_port_in_use() {
    local port=$1
    if command -v ss &> /dev/null; then
      ss -tuln 2>/dev/null | grep -q ":$port "
    elif command -v netstat &> /dev/null; then
      netstat -tuln 2>/dev/null | grep -q ":$port "
    else
      timeout 1 bash -c "echo > /dev/tcp/localhost/$port" 2>/dev/null
    fi
  }
  
  should_avoid_port() {
    local port=$1
    for avoid_port in "${AVOID_PORTS[@]}"; do
      if [ "$port" -eq "$avoid_port" ]; then
        return 0
      fi
    done
    return 1
  }
  
  for port in {5001..5100}; do
    if should_avoid_port $port; then
      continue
    fi
    if ! is_port_in_use $port; then
      FOUND_PORT=$port
      break
    fi
  done
  
  if [ -z "$FOUND_PORT" ]; then
    printf "${RED}❌ Não foi possível encontrar uma porta disponível (tentou 5001-5100)${NC}\n"
    printf "${YELLOW}Pressione ENTER para continuar...${NC}\n"
    read -r
    return 1
  fi
  
  printf "${GREEN}✓ Porta disponível encontrada: ${FOUND_PORT}${NC}\n"
  
  # Criar diretórios necessários
  mkdir -p "$TRANSCREVE_DIR/uploads" "$TRANSCREVE_DIR/logs"
  
  # Criar/atualizar docker-compose.yaml
  printf "${YELLOW}📝 Configurando docker-compose.yaml...${NC}\n"
  
  cat > "$TRANSCREVE_DIR/docker-compose.yaml" << EOF
version: '3.8'

services:
  api:
    build: 
      context: .
      dockerfile: Dockerfile
    container_name: transcreve-api-${instancia_name}
    ports:
      - "${FOUND_PORT}:5000"
    environment:
      - TZ=America/Sao_Paulo
      - PYTHONPATH=/transcreve-api/venv
      - ALLOWED_IPS=127.0.0.1,${SERVER_IP}
    volumes:
      - ./uploads:/transcreve-api/uploads  
      - ./logs:/transcreve-api/logs        
    restart: always
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://localhost:5000/"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
    deploy:
      resources:
        limits:
          memory: 2G
        reservations:
          memory: 1G

networks:
  default:
    driver: bridge
EOF
  
  printf "${GREEN}✓ docker-compose.yaml configurado${NC}\n"
  
  # Parar e remover containers existentes para esta instância
  printf "${YELLOW}🛑 Verificando containers existentes...${NC}\n"
  
  if $DOCKER_CMD ps -a | grep -q "transcreve-api-${instancia_name}"; then
    printf "${YELLOW}Container existente encontrado. Parando e removendo...${NC}\n"
    cd "$TRANSCREVE_DIR"
    $DOCKER_COMPOSE_CMD down 2>/dev/null || true
    $DOCKER_CMD rm -f "transcreve-api-${instancia_name}" 2>/dev/null || true
    sleep 2
  fi
  
  # Construir e iniciar o container
  printf "${YELLOW}🔨 Construindo imagem Docker...${NC}\n"
  
  cd "$TRANSCREVE_DIR"
  $DOCKER_COMPOSE_CMD build --no-cache
  
  printf "${YELLOW}🚀 Iniciando container Docker...${NC}\n"
  $DOCKER_COMPOSE_CMD up -d
  
  printf "${GREEN}✓ Container iniciado${NC}\n"
  
  # Aguardar API iniciar
  printf "${YELLOW}⏳ Aguardando API iniciar (pode levar até 60 segundos)...${NC}\n"
  
  MAX_WAIT=60
  WAIT_TIME=0
  HEALTHY=false
  
  while [ $WAIT_TIME -lt $MAX_WAIT ]; do
    if curl -s -f "http://localhost:${FOUND_PORT}/" > /dev/null 2>&1; then
      HEALTHY=true
      break
    fi
    sleep 2
    WAIT_TIME=$((WAIT_TIME + 2))
    echo -n "."
  done
  echo ""
  
  if [ "$HEALTHY" = true ]; then
    printf "${GREEN}✓ API está respondendo!${NC}\n"
  else
    printf "${YELLOW}⚠ API pode não estar respondendo ainda. Verifique os logs: $DOCKER_COMPOSE_CMD logs${NC}\n"
  fi
  
  # Atualizar arquivo .env do backend
  BACKEND_ENV="/home/deploy/${instancia_name}/backend/.env"
  
  if [ -f "$BACKEND_ENV" ]; then
    printf "${YELLOW}📝 Atualizando arquivo .env do backend...${NC}\n"
    
    # Criar backup
    BACKUP_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    cp "$BACKEND_ENV" "${BACKEND_ENV}.backup.${BACKUP_TIMESTAMP}"
    printf "${GREEN}✓ Backup criado: ${BACKEND_ENV}.backup.${BACKUP_TIMESTAMP}${NC}\n"
    
    # Determinar URL da API
    API_URL="http://${SERVER_IP}:${FOUND_PORT}/transcrever"
    
    # Atualizar ou adicionar TRANSCREVE_API_URL
    if grep -q "TRANSCREVE_API_URL" "$BACKEND_ENV"; then
      # Atualizar linha existente
      sed -i "s|TRANSCREVE_API_URL=.*|TRANSCREVE_API_URL=${API_URL}|" "$BACKEND_ENV"
      printf "${GREEN}✓ Variável TRANSCREVE_API_URL atualizada no .env${NC}\n"
    else
      # Adicionar nova linha
      echo "" >> "$BACKEND_ENV"
      echo "# API de Transcrição de Áudio" >> "$BACKEND_ENV"
      echo "TRANSCREVE_API_URL=${API_URL}" >> "$BACKEND_ENV"
      printf "${GREEN}✓ Variável TRANSCREVE_API_URL adicionada ao .env${NC}\n"
    fi
    
    printf "${GREEN}✓ URL configurada: ${API_URL}${NC}\n"
    
    # Rebuild do backend - build como root, restart como deploy
    printf "${YELLOW}🔨 Reconstruindo backend...${NC}\n"
    
    # Instalar dependências se necessário (como root)
    if [ ! -d "/home/deploy/${instancia_name}/backend/node_modules" ]; then
      printf "${YELLOW}📦 Instalando dependências...${NC}\n"
      cd "/home/deploy/${instancia_name}/backend"
      npm install
    fi
    
    # Build do backend (como root)
    printf "${YELLOW}🔨 Executando build do backend...${NC}\n"
    cd "/home/deploy/${instancia_name}/backend"
    npm run build
    
    printf "${GREEN}✓ Build do backend concluído${NC}\n"
    
    # Reiniciar PM2 (como usuário deploy)
    printf "${YELLOW}🔄 Reiniciando processos PM2...${NC}\n"
    
    sudo su - deploy <<EOF
    cd /home/deploy/${instancia_name}
    pm2 restart ${instancia_name}-backend
    pm2 save
EOF
    
    printf "${GREEN}✓ Processos PM2 reiniciados${NC}\n"
    
  else
    printf "${RED}❌ Arquivo .env do backend não encontrado: ${BACKEND_ENV}${NC}\n"
    printf "${YELLOW}Adicione manualmente ao arquivo .env do backend:${NC}\n"
    printf "${YELLOW}TRANSCREVE_API_URL=http://${SERVER_IP}:${FOUND_PORT}/transcrever${NC}\n"
  fi
  
  sleep 2
  
  print_banner
  printf "${GREEN} ✅ Instalação do transcreveAPI concluída com sucesso!${NC}\n"
  printf "\n"
  printf "${YELLOW}Informações da instalação:${NC}\n"
  printf "  ${YELLOW}Instância:${NC} ${instancia_name}\n"
  printf "  ${YELLOW}IP do Servidor:${NC} ${SERVER_IP}\n"
  printf "  ${YELLOW}Porta:${NC} ${FOUND_PORT}\n"
  printf "  ${YELLOW}URL da API:${NC} http://${SERVER_IP}:${FOUND_PORT}/transcrever\n"
  printf "  ${YELLOW}Container:${NC} transcreve-api-${instancia_name}\n"
  printf "\n"
  printf "${YELLOW}Pressione ENTER para continuar...${NC}\n"
  read -r
}

#######################################
# Seleciona uma instância e instala o transcreveAPI
# Arguments:
#   None
#######################################
software_transcreve_install() {
  print_banner
  printf "${YELLOW} 💻 Selecione a instância para instalar o transcreveAPI:${GRAY_LIGHT}"
  printf "\n\n"
  
  # Listar instâncias disponíveis
  instance_list=()
  instance_index=0
  
  if [ -d "/home/deploy" ]; then
    for dir in /home/deploy/*/; do
      if [ -d "$dir" ]; then
        instance_name=$(basename "$dir")
        
        # Verificar se tem frontend e backend (é uma instalação whaticket)
        if [ -d "$dir/frontend" ] && [ -d "$dir/backend" ]; then
          instance_index=$((instance_index + 1))
          instance_list+=("$instance_name")
          printf "   [${instance_index}] ${instance_name}\n"
        fi
      fi
    done
  fi
  
  if [ ${#instance_list[@]} -eq 0 ]; then
    printf "${RED}❌ Nenhuma instalação encontrada!${NC}\n"
    printf "${YELLOW}Por favor, instale o Whaticket primeiro.${NC}\n"
    printf "${YELLOW}Pressione ENTER para continuar...${NC}\n"
    read -r
    return 1
  fi
  
  printf "\n"
  read -p "> " selected_option
  
  # Validar seleção
  if ! [[ "$selected_option" =~ ^[0-9]+$ ]] || [ "$selected_option" -lt 1 ] || [ "$selected_option" -gt ${#instance_list[@]} ]; then
    printf "${RED}❌ Opção inválida!${NC}\n"
    printf "${YELLOW}Pressione ENTER para continuar...${NC}\n"
    read -r
    return 1
  fi
  
  selected_instance="${instance_list[$((selected_option - 1))]}"
  
  printf "\n"
  printf "${YELLOW}Instância selecionada: ${selected_instance}${NC}\n"
  printf "${YELLOW}Iniciando instalação do transcreveAPI...${NC}\n\n"
  
  sleep 2
  
  # Chamar função de instalação
  install_transcreve_api "$selected_instance"
}

#######################################
# Remove o transcreveAPI de uma instância específica
# Arguments:
#   instancia_name - Nome da instância
#######################################
uninstall_transcreve_api() {
  local instancia_name=$1
  
  print_banner
  printf "${YELLOW} 💻 Removendo transcreveAPI da instância ${instancia_name}...${GRAY_LIGHT}"
  printf "\n\n"
  
  # Verificar se a instância existe
  if [ ! -d "/home/deploy/${instancia_name}" ]; then
    printf "${RED}❌ Instância ${instancia_name} não encontrada!${NC}\n"
    printf "${YELLOW}Pressione ENTER para continuar...${NC}\n"
    read -r
    return 1
  fi
  
  # Verificar se o container Docker existe
  container_name="transcreve-api-${instancia_name}"
  
  printf "${YELLOW}🔍 Verificando container Docker...${NC}\n"
  
  # Verificar se docker compose está disponível
  if docker compose version &> /dev/null; then
    DOCKER_COMPOSE_CMD="docker compose"
  elif command -v docker-compose &> /dev/null; then
    DOCKER_COMPOSE_CMD="docker-compose"
  else
    printf "${YELLOW}⚠ Docker Compose não encontrado, tentando com docker diretamente...${NC}\n"
    DOCKER_COMPOSE_CMD=""
  fi
  
  # Verificar permissões Docker
  if ! docker ps &> /dev/null; then
    DOCKER_CMD="sudo docker"
    if [ -n "$DOCKER_COMPOSE_CMD" ]; then
      DOCKER_COMPOSE_CMD="sudo $DOCKER_COMPOSE_CMD"
    fi
  else
    DOCKER_CMD="docker"
  fi
  
  # Verificar se o container existe
  container_exists=false
  if $DOCKER_CMD ps -a --format "{{.Names}}" 2>/dev/null | grep -q "^${container_name}$"; then
    container_exists=true
    printf "${GREEN}✓ Container encontrado: ${container_name}${NC}\n"
  else
    printf "${YELLOW}⚠ Container ${container_name} não encontrado.${NC}\n"
    printf "${YELLOW}Verificando outros containers transcreve-api...${NC}\n"
    
    # Verificar se existe algum container relacionado
    related_containers=$($DOCKER_CMD ps -a --format "{{.Names}}" 2>/dev/null | grep "transcreve" | grep -v "^${container_name}$" || true)
    if [ -n "$related_containers" ]; then
      printf "${YELLOW}Containers relacionados encontrados:${NC}\n"
      echo "$related_containers" | while read -r container; do
        printf "  - ${container}\n"
      done
    fi
  fi
  
  sleep 2
  
  # Parar e remover o container Docker
  if [ "$container_exists" = true ]; then
    printf "${YELLOW}🛑 Parando container Docker...${NC}\n"
    
    $DOCKER_CMD stop "${container_name}" 2>/dev/null || true
    sleep 2
    
    printf "${YELLOW}🗑️  Removendo container Docker...${NC}\n"
    $DOCKER_CMD rm -f "${container_name}" 2>/dev/null || true
    
    printf "${GREEN}✓ Container removido com sucesso${NC}\n"
  else
    printf "${YELLOW}⚠ Nenhum container encontrado para remover.${NC}\n"
  fi
  
  # Remover variável TRANSCREVE_API_URL do .env do backend
  BACKEND_ENV="/home/deploy/${instancia_name}/backend/.env"
  
  if [ -f "$BACKEND_ENV" ]; then
    printf "${YELLOW}📝 Removendo configuração do arquivo .env do backend...${NC}\n"
    
    # Criar backup
    BACKUP_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    cp "$BACKEND_ENV" "${BACKEND_ENV}.backup.${BACKUP_TIMESTAMP}"
    printf "${GREEN}✓ Backup criado: ${BACKEND_ENV}.backup.${BACKUP_TIMESTAMP}${NC}\n"
    
    # Remover variável TRANSCREVE_API_URL
    if grep -q "TRANSCREVE_API_URL" "$BACKEND_ENV"; then
      # Remover linha(s) com TRANSCREVE_API_URL e comentários relacionados
      sed -i '/# API de Transcrição de Áudio/d' "$BACKEND_ENV"
      sed -i '/^TRANSCREVE_API_URL=/d' "$BACKEND_ENV"
      # Remover linhas vazias duplicadas
      sed -i '/^$/N;/^\n$/d' "$BACKEND_ENV"
      
      printf "${GREEN}✓ Variável TRANSCREVE_API_URL removida do .env${NC}\n"
    else
      printf "${YELLOW}⚠ Variável TRANSCREVE_API_URL não encontrada no .env${NC}\n"
    fi
    
    # Perguntar se deseja reconstruir e reiniciar o backend
    printf "\n"
    printf "${YELLOW}Deseja reconstruir e reiniciar o backend para aplicar as mudanças? (S/n): ${NC}"
    read -r rebuild_backend
    
    if [ -z "$rebuild_backend" ] || [ "$rebuild_backend" = "S" ] || [ "$rebuild_backend" = "s" ]; then
      # Rebuild do backend - build como root, restart como deploy
      printf "${YELLOW}🔨 Reconstruindo backend...${NC}\n"
      
      # Build do backend (como root)
      printf "${YELLOW}🔨 Executando build do backend...${NC}\n"
      cd "/home/deploy/${instancia_name}/backend"
      npm run build
      
      printf "${GREEN}✓ Build do backend concluído${NC}\n"
      
      # Reiniciar PM2 (como usuário deploy)
      printf "${YELLOW}🔄 Reiniciando processos PM2...${NC}\n"
      
      sudo su - deploy <<EOF
      cd /home/deploy/${instancia_name}
      pm2 restart ${instancia_name}-backend
      pm2 save
EOF
      
      printf "${GREEN}✓ Processos PM2 reiniciados${NC}\n"
    else
      printf "${YELLOW}⚠ Backend não foi reconstruído. Lembre-se de reiniciá-lo manualmente.${NC}\n"
    fi
    
  else
    printf "${YELLOW}⚠ Arquivo .env do backend não encontrado: ${BACKEND_ENV}${NC}\n"
    printf "${YELLOW}Remova manualmente a variável TRANSCREVE_API_URL se existir.${NC}\n"
  fi
  
  sleep 2
  
  print_banner
  printf "${GREEN} ✅ Remoção do transcreveAPI concluída com sucesso!${NC}\n"
  printf "\n"
  printf "${YELLOW}Informações:${NC}\n"
  printf "  ${YELLOW}Instância:${NC} ${instancia_name}\n"
  printf "  ${YELLOW}Container:${NC} ${container_name}\n"
  printf "\n"
  if [ -f "$BACKEND_ENV" ]; then
    printf "${GREEN}✓ Configuração removida do .env do backend${NC}\n"
  fi
  printf "\n"
  printf "${YELLOW}Pressione ENTER para continuar...${NC}\n"
  read -r
}

#######################################
# Seleciona uma instância e remove o transcreveAPI
# Arguments:
#   None
#######################################
software_transcreve_uninstall() {
  print_banner
  printf "${YELLOW} 💻 Selecione a instância para remover o transcreveAPI:${GRAY_LIGHT}"
  printf "\n\n"
  
  # Verificar containers Docker do transcreveAPI
  if ! command -v docker &> /dev/null; then
    printf "${RED}❌ Docker não encontrado!${NC}\n"
    printf "${YELLOW}O transcreveAPI requer Docker para funcionar.${NC}\n"
    printf "${YELLOW}Pressione ENTER para continuar...${NC}\n"
    read -r
    return 1
  fi
  
  # Verificar permissões Docker
  if ! docker ps &> /dev/null; then
    DOCKER_CMD="sudo docker"
  else
    DOCKER_CMD="docker"
  fi
  
  printf "${YELLOW}🔍 Buscando instalações do transcreveAPI...${NC}\n\n"
  
  # Listar instâncias que têm transcreveAPI instalado
  instance_list=()
  instance_index=0
  
  if [ -d "/home/deploy" ]; then
    for dir in /home/deploy/*/; do
      if [ -d "$dir" ]; then
        instance_name=$(basename "$dir")
        
        # Verificar se tem frontend e backend (é uma instalação whaticket)
        if [ -d "$dir/frontend" ] && [ -d "$dir/backend" ]; then
          # Verificar se existe container Docker para esta instância
          container_name="transcreve-api-${instance_name}"
          if $DOCKER_CMD ps -a --format "{{.Names}}" 2>/dev/null | grep -q "^${container_name}$"; then
            instance_index=$((instance_index + 1))
            instance_list+=("$instance_name")
            
            # Verificar status do container
            container_status=$($DOCKER_CMD inspect --format='{{.State.Status}}' "$container_name" 2>/dev/null || echo "unknown")
            
            printf "   [${instance_index}] ${instance_name}"
            if [ "$container_status" = "running" ]; then
              printf " ${GREEN}(Rodando)${NC}\n"
            elif [ "$container_status" = "stopped" ]; then
              printf " ${YELLOW}(Parado)${NC}\n"
            else
              printf " ${RED}(${container_status})${NC}\n"
            fi
          fi
        fi
      fi
    done
  fi
  
  if [ ${#instance_list[@]} -eq 0 ]; then
    printf "${RED}❌ Nenhuma instalação do transcreveAPI encontrada!${NC}\n"
    printf "${YELLOW}Pressione ENTER para continuar...${NC}\n"
    read -r
    return 1
  fi
  
  printf "\n"
  read -p "> " selected_option
  
  # Validar seleção
  if ! [[ "$selected_option" =~ ^[0-9]+$ ]] || [ "$selected_option" -lt 1 ] || [ "$selected_option" -gt ${#instance_list[@]} ]; then
    printf "${RED}❌ Opção inválida!${NC}\n"
    printf "${YELLOW}Pressione ENTER para continuar...${NC}\n"
    read -r
    return 1
  fi
  
  selected_instance="${instance_list[$((selected_option - 1))]}"
  
  printf "\n"
  printf "${YELLOW}Instância selecionada: ${selected_instance}${NC}\n"
  printf "${RED}⚠ ATENÇÃO: Esta ação irá remover o transcreveAPI desta instância!${NC}\n"
  printf "${YELLOW}Deseja continuar? (s/N): ${NC}"
  read -r confirm
  
  if [ "$confirm" != "s" ] && [ "$confirm" != "S" ]; then
    printf "${YELLOW}Operação cancelada.${NC}\n"
    printf "${YELLOW}Pressione ENTER para continuar...${NC}\n"
    read -r
    return 0
  fi
  
  printf "\n"
  printf "${YELLOW}Iniciando remoção do transcreveAPI...${NC}\n\n"
  
  sleep 2
  
  # Chamar função de remoção
  uninstall_transcreve_api "$selected_instance"
}

