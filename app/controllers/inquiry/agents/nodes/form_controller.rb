class Inquiry::Agents::Nodes::FormController < ApplicationController
  include Cms::NodeFilter::View
  include Cms::ForMemberFilter::Node
  include SS::CaptchaFilter
  helper Inquiry::FormHelper

  before_action :check_release_state, only: [:new, :confirm, :create, :sent, :results], if: ->{ !@preview }
  before_action :check_reception_state, only: [:new, :confirm, :create, :sent], if: ->{ !@preview }
  before_action :check_aggregation_state, only: :results, if: ->{ !@preview }
  before_action :set_columns, only: [:new, :confirm, :create, :sent, :results]
  before_action :set_answer, only: [:new, :confirm, :create]

  private

  def protect_csrf?
    false
  end

  def check_release_state
    raise "404" unless @cur_node.public?
  end

  def check_reception_state
    raise "404" unless @cur_node.reception_enabled?
  end

  def check_aggregation_state
    raise "404" unless @cur_node.aggregation_enabled?
  end

  def set_columns
    @columns = Inquiry::Column.site(@cur_site).
      where(node_id: @cur_node.id, state: "public").
      order_by(order: 1)
  end

  def set_answer
    @items = []
    @data = {}
    @to = [@cur_node.notice_email]
    @columns.each do |column|
      param = params.to_unsafe_h[:item].try(:[], column.id.to_s)
      if column.input_type == "upload_file" &&
         !param.blank? &&
         !param.kind_of?(ActionDispatch::Http::UploadedFile)

        client_name = Inquiry::Answer.persistence_context.send(:client_name)
        param = SS::File.with(client: client_name) do |model|
          model.find(param)
        end
      end
      @items << [column, param]
      @data[column.id] = [param]
      if (column.input_type == 'text_field' || column.input_type == 'text_area') && column.transfers.present? && param.present?
        column.transfers.each do |transfer|
          next if transfer[:email].blank? || transfer[:keyword].blank?
          @to.push(transfer[:email]) if param.include?(transfer[:keyword])
        end
      end
      if column.input_confirm == "enabled"
        @items.last << params[:item].try(:[], "#{column.id}_confirm")
        @data[column.id] << params[:item].try(:[], "#{column.id}_confirm")
      end
    end
    @to = @to.uniq.compact.sort
    @answer = Inquiry::Answer.new(cur_site: @cur_site, cur_node: @cur_node)
    @answer.remote_addr = remote_addr
    @answer.user_agent = request.user_agent
    @answer.member = @cur_member
    @answer.source_url = params[:item].try(:[], :source_url)
    @answer.set_data(@data)
  end

  def set_group
    return if params[:group].blank?

    @group = Cms::Group.site(@cur_site).where(id: params[:group]).first
    raise "404" if @group.blank?
    raise "404" if @cur_node.notify_mail_enabled? && @group.contact_email.blank?
  end

  def set_page
    return if params[:page].blank?

    @page = Cms::Page.site(@cur_site).and_public.where(id: params[:page]).first
    raise "404" if @page.blank?
  end

  public

  def new
    set_group
    set_page
    if @group || @page
      raise "404" if @cur_site.inquiry_form != @cur_node
    end
    if @group && @page
      raise "404" if @page.contact_group_id != @group.id
    end
  end

  def confirm
    set_group
    set_page
    if !@answer.valid?
      render action: :new
    end
  end

  def create
    set_group
    set_page
    if !@answer.valid? || params[:submit].blank?
      render action: :new
      return
    end

    if @cur_node.captcha_enabled? && get_captcha[:captcha_error].nil?
      unless captcha_valid?(@answer)
        render action: :confirm
        return
      end
    end

    @answer.group_ids = @group ? [ @group.id ] : @cur_node.group_ids

    if @page
      @answer.inquiry_page_url = @page.url
      @answer.inquiry_page_name = @page.name
    end

    @answer.save
    if @cur_node.notify_mail_enabled?
      if @group.present? && @group.contact_email.present?
        notice_email = @group.contact_email
        Inquiry::Mailer.notify_mail(@cur_site, @cur_node, @answer, notice_email).deliver_now if notice_email.present?
      else
        @to.each { |notice_email| Inquiry::Mailer.notify_mail(@cur_site, @cur_node, @answer, notice_email).deliver_now }
      end
    end

    if @cur_node.reply_mail_enabled?
      # `try` method doesn't work as you think because mail is an instance of Delegator.
      # see: http://tech.misoca.jp/entry/2015/12/04/110000
      mail = Inquiry::Mailer.reply_mail(@cur_site, @cur_node, @answer)
      mail.deliver_now if mail.present?
    end

    if @cur_node.try(:kintone_app_enabled?)
      @answer.update_kintone_record
    end

    query = {}
    if @answer.source_url.present?
      if params[:preview]
        query[:ref] = view_context.cms_preview_path(site: @cur_site, path: @answer.source_content.url[1..-1])
      else
        query[:ref] = @answer.source_url
      end
    end
    query[:group] = @group.id if @group
    query = query.to_query

    url = "#{@cur_node.url}sent.html"
    url = "#{url}?#{query}" if query.present?
    redirect_to url
  end

  def sent
    set_group
    render action: :sent
  end

  def results
    @cur_node.name = "#{@cur_node.name} #{I18n.t("inquiry.result")}"
    @aggregation = @cur_node.aggregate_select_columns
    render action: :results
  end
end
