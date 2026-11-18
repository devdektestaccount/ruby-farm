require 'json'
require 'date'
require 'securerandom'

module SistemaBiblioteca
  # Exceções personalizadas para regras de negócio
  class ErroBiblioteca < StandardError; end
  class ItemIndisponivelError < ErroBiblioteca; end
  class LimiteEmprestimosError < ErroBiblioteca; end
  class UsuarioBloqueadoError < ErroBiblioteca; end
  class RegistroNaoEncontradoError < ErroBiblioteca; end

  # Módulo para registro de auditoria e logs
  module Auditavel
    def registrar_log(acao, detalhes)
      timestamp = Time.now.strftime('%Y-%m-%d %H:%M:%S')
      @logs ||= []
      @logs << { data: timestamp, acao: acao, detalhes: detalhes }
    end

    def exibir_logs
      @logs ||= []
      puts "\n--- HISTÓRICO DE AUDITORIA ---"
      @logs.each do |log|
        puts "[#{log[:data]}] #{log[:acao].upcase}: #{log[:detalhes]}"
      end
    end
  end

  # Classe base para itens do acervo
  class ItemAcervo
    attr_reader :id, :titulo, :ano_publicacao, :categoria
    attr_accessor :disponivel

    def initialize(titulo, ano_publicacao, categoria, id: SecureRandom.hex(4), disponivel: true)
      @id = id
      @titulo = titulo
      @ano_publicacao = ano_publicacao
      @categoria = categoria
      @disponivel = disponivel
    end

    def taxa_multa_diaria
      2.50
    end

    def prazo_dias_emprestimo
      14
    end

    def to_h
      {
        tipo: self.class.name.split('::').last,
        id: @id,
        titulo: @titulo,
        ano_publicacao: @ano_publicacao,
        categoria: @categoria,
        disponivel: @disponivel
      }
    end

    def to_s
      status = @disponivel ? 'Disponível' : 'Emprestado'
      "[#{@id}] #{@titulo} (#{@ano_publicacao}) - #{@categoria} | Status: #{status}"
    end
  end

  class Livro < ItemAcervo
    attr_reader :autor, :isbn, :paginas

    def initialize(titulo, autor, ano_publicacao, categoria, isbn, paginas, **opts)
      super(titulo, ano_publicacao, categoria, **opts)
      @autor = autor
      @isbn = isbn
      @paginas = paginas
    end

    def to_h
      super.merge(autor: @autor, isbn: @isbn, paginas: @paginas)
    end

    def to_s
      "#{super} | Autor: #{@autor} | ISBN: #{@isbn}"
    end
  end

  class Revista < ItemAcervo
    attr_reader :edicao, :editora

    def initialize(titulo, editora, edicao, ano_publicacao, categoria, **opts)
      super(titulo, ano_publicacao, categoria, **opts)
      @editora = editora
      @edicao = edicao
    end

    def taxa_multa_diaria
      1.50
    end

    def prazo_dias_emprestimo
      7
    end

    def to_h
      super.merge(editora: @editora, edicao: @edicao)
    end

    def to_s
      "#{super} | Editora: #{@editora} (Ed. #{@edicao})"
    end
  end

  # Classe de Membro/Usuário
  class Membro
    attr_reader :id, :nome, :email, :limite_itens
    attr_accessor :multas_pendentes, :itens_emprestados

    def initialize(nome, email, limite_itens: 3, id: SecureRandom.hex(4), multas_pendentes: 0.0, itens_emprestados: [])
      @id = id
      @nome = nome
      @email = email
      @limite_itens = limite_itens
      @multas_pendentes = multas_pendentes
      @itens_emprestados = itens_emprestados
    end

    def pode_emprestar?
      @multas_pendentes <= 0.0 && @itens_emprestados.size < @limite_itens
    end

    def pagar_multa(valor)
      raise ErroBiblioteca, 'Valor inválido para pagamento.' if valor <= 0

      @multas_pendentes = [@multas_pendentes - valor, 0.0].max
    end

    def to_h
      {
        id: @id,
        nome: @nome,
        email: @email,
        limite_itens: @limite_itens,
        multas_pendentes: @multas_pendentes,
        itens_emprestados: @itens_emprestados
      }
    end

    def to_s
      "Membro [#{@id}]: #{@nome} (#{@email}) | Empréstimos ativos: #{@itens_emprestados.size}/#{@limite_itens} | Multas: R$ #{format('%.2f', @multas_pendentes)}"
    end
  end

  # Classe que representa uma transação de empréstimo
  class Emprestimo
    attr_reader :id, :membro_id, :item_id, :data_emprestimo, :data_prevista
    attr_accessor :data_devolucao, :multa_gerada

    def initialize(membro_id, item_id, prazo_dias, id: SecureRandom.hex(4), data_emprestimo: Date.today, data_prevista: nil, data_devolucao: nil, multa_gerada: 0.0)
      @id = id
      @membro_id = membro_id
      @item_id = item_id
      @data_emprestimo = data_emprestimo.is_a?(String) ? Date.parse(data_emprestimo) : data_emprestimo
      @data_prevista = if data_prevista
                         data_prevista.is_a?(String) ? Date.parse(data_prevista) : data_prevista
                       else
                         @data_emprestimo + prazo_dias
                       end
      @data_devolucao = data_devolucao.is_a?(String) ? Date.parse(data_devolucao) : data_devolucao
      @multa_gerada = multa_gerada
    end

    def ativo?
      @data_devolucao.nil?
    end

    def dias_atraso(data_referencia = Date.today)
      data_fim = @data_devolucao || data_referencia
      atraso = (data_fim - @data_prevista).to_i
      atraso.positive? ? atraso : 0
    end

    def to_h
      {
        id: @id,
        membro_id: @membro_id,
        item_id: @item_id,
        data_emprestimo: @data_emprestimo.to_s,
        data_prevista: @data_prevista.to_s,
        data_devolucao: @data_devolucao&.to_s,
        multa_gerada: @multa_gerada
      }
    end
  end

  # Controlador principal da Biblioteca
  class Biblioteca
    include Auditavel

    attr_reader :nome, :acervo, :membros, :emprestimos

    def initialize(nome, arquivo_dados = 'biblioteca_dados.json')
      @nome = nome
      @arquivo_dados = arquivo_dados
      @acervo = {}
      @membros = {}
      @emprestimos = {}
      @logs = []
    end

    def adicionar_item(item)
      @acervo[item.id] = item
      registrar_log('cadastro_item', "Item '#{item.titulo}' adicionado ao acervo.")
      item
    end

    def cadastrar_membro(membro)
      @membros[membro.id] = membro
      registrar_log('cadastro_membro', "Membro '#{membro.nome}' cadastrado.")
      membro
    end

    def buscar_acervo(termo)
      termo_down = termo.downcase
      @acervo.values.select do |item|
        item.titulo.downcase.include?(termo_down) ||
          item.categoria.downcase.include?(termo_down) ||
          (item.respond_to?(:autor) && item.autor.downcase.include?(termo_down))
      end
    end

    def realizar_emprestimo(membro_id, item_id, data_simulacao: Date.today)
      membro = buscar_membro!(membro_id)
      item = buscar_item!(item_id)

      raise ItemIndisponivelError, "O item '#{item.titulo}' já está emprestado." unless item.disponivel
      raise UsuarioBloqueadoError, "Membro possui multas pendentes de R$ #{format('%.2f', membro.multas_pendentes)}." if membro.multas_pendentes.positive?
      raise LimiteEmprestimosError, "Membro atingiu o limite de #{membro.limite_itens} itens." if membro.itens_emprestados.size >= membro.limite_itens

      emprestimo = Emprestimo.new(membro.id, item.id, item.prazo_dias_emprestimo, data_emprestimo: data_simulacao)
      item.disponivel = false
      membro.itens_emprestados << item.id
      @emprestimos[emprestimo.id] = emprestimo

      registrar_log('emprestimo', "Item '#{item.titulo}' emprestado para '#{membro.nome}'. Devolução até #{emprestimo.data_prevista}.")
      emprestimo
    end

    def registrar_devolucao(emprestimo_id, data_devolucao: Date.today)
      emprestimo = @emprestimos[emprestimo_id]
      raise RegistroNaoEncontradoError, 'Empréstimo não encontrado.' unless emprestimo
      raise ErroBiblioteca, 'Este empréstimo já foi finalizado.' unless emprestimo.ativo?

      item = buscar_item!(emprestimo.item_id)
      membro = buscar_membro!(emprestimo.membro_id)

      emprestimo.data_devolucao = data_devolucao
      atraso = emprestimo.dias_atraso(data_devolucao)

      if atraso.positive?
        multa = atraso * item.taxa_multa_diaria
        emprestimo.multa_gerada = multa
        membro.multas_pendentes += multa
      end

      item.disponivel = true
      membro.itens_emprestados.delete(item.id)

      registrar_log('devolucao', "Item '#{item.titulo}' devolvido por '#{membro.nome}'. Atraso: #{atraso} dias. Multa: R$ #{format('%.2f', emprestimo.multa_gerada)}.")
      emprestimo
    end

    def gerar_relatorio_geral
      total_itens = @acervo.size
      disponiveis = @acervo.values.count(&:disponivel)
      emprestados = total_itens - disponiveis
      total_multas = @membros.values.sum(&:multas_pendentes)

      puts "\n=========================================="
      puts "RELATÓRIO GERENCIAL - #{@nome.upcase}"
      puts "=========================================="
      puts "Total de itens no acervo : #{total_itens}"
      puts "Itens disponíveis        : #{disponiveis}"
      puts "Itens emprestados        : #{emprestados}"
      puts "Membros cadastrados      : #{@membros.size}"
      puts "Empréstimos históricos   : #{@emprestimos.size}"
      puts "Multas pendentes totais  : R$ #{format('%.2f', total_multas)}"
      puts "==========================================\n"
    end

    def salvar_em_json
      dados = {
        nome: @nome,
        acervo: @acervo.values.map(&:to_h),
        membros: @membros.values.map(&:to_h),
        emprestimos: @emprestimos.values.map(&:to_h),
        logs: @logs
      }
      File.write(@arquivo_dados, JSON.pretty_generate(dados))
      registrar_log('persistencia', "Dados salvos em #{@arquivo_dados}.")
    end

    def carregar_de_json
      return false unless File.exist?(@arquivo_dados)

      dados = JSON.parse(File.read(@arquivo_dados), symbolize_names: true)
      @nome = dados[:nome]
      @acervo.clear
      @membros.clear
      @emprestimos.clear

      dados[:acervo].each do |item_h|
        item = if item_h[:tipo] == 'Livro'
                 Livro.new(item_h[:titulo], item_h[:autor], item_h[:ano_publicacao], item_h[:categoria], item_h[:isbn], item_h[:paginas], id: item_h[:id], disponivel: item_h[:disponivel])
               else
