uninstall_transcreve_api() {
  local instancia_name=$1
  
  print_banner
  printf "${YELLOW} 💻 Removendo transcreveAPI da instância ${instancia_name}...${GRAY_LIGHT}"
  printf "\n\n"
  
  if [ ! -d "/home/deploy/${instancia_name}" ]; then
    printf "${RED}❌ Instância ${instancia_name} não encontrada!${NC}\n"
    printf "${YELLOW}Pressione ENTER para continuar...${NC}\n"
    read -r
    return 1
  fi
  
  container_name="transcreve-api-${instancia_name}"
  
  printf "${YELLOW}🔍 Verificando container Docker...${NC}\n"
  
  if docker ps -a | grep -q "$container_name"; then
    printf "${YELLOW}🛑 Parando e removendo container...${NC}\n"
    cd "/home/deploy/${instancia_name}/transcreveAPI"
    
    if docker compose version &> /dev/null; then
      docker compose down 2>/dev/null || true
    elif command -v docker-compose &> /dev/null; then
      docker-compose down 2>/dev/null || true
    fi
    
    docker rm -f "$container_name" 2>/dev/null || true
  else
    printf "${YELLOW}⚠ Nenhum container encontrado para ${container_name}${NC}\n"
  fi
  
  COMPOSE_FILE="/home/deploy/${instancia_name}/transcreveAPI/docker-compose.yaml"
  if [ -f "$COMPOSE_FILE" ]; then
    rm -f "$COMPOSE_FILE"
    printf "${GREEN}✓ docker-compose.yaml removido${NC}\n"
  fi
  
  BACKEND_ENV="/home/deploy/${instancia_name}/backend/.env"
  if [ -f "$BACKEND_ENV" ]; then
    if grep -q "TRANSCREVE_API_URL" "$BACKEND_ENV"; then
      sed -i '/TRANSCREVE_API_URL/d' "$BACKEND_ENV"
      sed -i '/API de Transcrição de Áudio/d' "$BACKEND_ENV"
      printf "${GREEN}✓ Variáveis removidas do .env${NC}\n"
    fi
  fi
  
  printf "${YELLOW}🔄 Reiniciando backend via PM2...${NC}\n"
  sudo su - deploy <<EOF
  pm2 restart ${instancia_name}-backend
  pm2 save
EOF
  
  print_banner
  printf "${GREEN}✅ transcreveAPI removido da instância ${instancia_name}!${NC}\n"
  printf "${YELLOW}Pressione ENTER para continuar...${NC}\n"
  read -r
}

software_transcreve_uninstall() {
  print_banner
  printf "${YELLOW} 💻 Selecione a instância para remover o transcreveAPI:${GRAY_LIGHT}"
  printf "\n\n"
  
  instance_list=()
  instance_index=0
  
  if [ -d "/home/deploy" ]; then
    for dir in /home/deploy/*/; do
      if [ -d "$dir" ]; then
        instance_name=$(basename "$dir")
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
    printf "${YELLOW}Pressione ENTER para continuar...${NC}\n"
    read -r
    return 1
  fi
  
  printf "\n"
  read -p "> " selected_option
  
  if ! [[ "$selected_option" =~ ^[0-9]+$ ]] || [ "$selected_option" -lt 1 ] || [ "$selected_option" -gt ${#instance_list[@]} ]; then
    printf "${RED}❌ Opção inválida!${NC}\n"
    printf "${YELLOW}Pressione ENTER para continuar...${NC}\n"
    read -r
    return 1
  fi
  
  selected_instance="${instance_list[$((selected_option - 1))]}"
  
  printf "\n"
  printf "${YELLOW}Instância selecionada: ${selected_instance}${NC}\n"
  printf "${YELLOW}Iniciando remoção do transcreveAPI...${NC}\n\n"
  
  sleep 2
  
  uninstall_transcreve_api "$selected_instance"
}
