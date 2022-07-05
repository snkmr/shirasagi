module Cms::PageImportBase
  extend ActiveSupport::Concern
  include Cms::CsvImportBase

  included do
    cattr_accessor :model, instance_accessor: false
    self.model = Cms::Page

    self.required_headers = ->{ [ model.t(:filename) ] }
    attr_reader :site, :node, :user
  end

  def initialize(site, node, user)
    @site = site
    @node = node
    @user = user
  end

  def import(file, opts = {})
    @task = opts[:task]
    put_log("import start " + ::File.basename(file.name))
    import_csv(file)
  end

  private

  def put_log(message)
    if @task
      @task.log(message)
    else
      Rails.logger.info(message)
    end
  end

  def import_csv(file)
    self.class.each_csv(file) do |row, i|
      i += 1
      item = update_row(row)
      put_log("update #{i + 1}: #{item.name}") if item.present?
    rescue => e
      put_log("error  #{i + 1}: #{e}")
    end
  end

  def update_row(row)
    filename = "#{node.filename}/#{value(row, :filename)}"
    item = self.class.model.find_or_initialize_by(site_id: site.id, filename: filename)
    raise I18n.t('errors.messages.auth_error') unless item.allowed?(:import, user, site: site, node: node)

    item.site = site
    item.event_recurrences = nil
    set_page_attributes(row, item)
    raise I18n.t('errors.messages.auth_error') unless item.allowed?(:import, user, site: site, node: node)

    if item.save
      item
    else
      raise item.errors.full_messages.join(", ")
    end
  end

  def value(row, key)
    key = self.class.model.t(key) if key.is_a?(Symbol)
    row[key].try(:strip)
  end

  delegate :to_array, :from_label, to: SS::Csv::CsvImporter

  def category_name_tree_to_ids(name_trees)
    category_ids = []
    name_trees.each do |cate|
      names = cate.split("/")

      last_index = names.size - 1
      last_name = names[last_index]

      parent_names = names.slice(0...(names.size - 1))

      cond = { name: last_name, depth: last_index + 1, route: /^category\// }
      node_ids = Cms::Node.site(site).where(cond).pluck(:id)
      node_ids.each do |node_id|
        cate = Cms::Node.find(node_id)

        if parent_names == cate.parents.pluck(:name)
          category_ids << cate.id
        end
      end
    end
    category_ids
  end

  def set_page_attributes(row, item)
    create_importer
    @importer.import_row(row, item)
  end

  def create_importer
    @importer ||= SS::Csv.draw(:import, context: self, model: self.class.model) do |importer|
      define_importer_basic(importer)
      define_importer_meta(importer)
      define_importer_body(importer)
      define_importer_category(importer)
      define_importer_parent_crumb(importer)
      define_importer_event_date(importer)
      define_importer_related_pages(importer)
      define_importer_contact_page(importer)
      define_importer_released(importer)
      define_importer_groups(importer)
      define_importer_state(importer)
      define_importer_forms(importer)
    end.create
  end

  def define_importer_basic(importer)
    importer.simple_column :name
    importer.simple_column :index_name
    importer.simple_column :layout do |row, item, head, value|
      item.layout = value.present? ? Cms::Layout.site(site).where(name: value).first : nil
    end
    importer.simple_column :body_layout_id do |row, item, head, value|
      item.body_layout = value.present? ? Cms::BodyLayout.site(site).where(name: value).first : nil
    end
    importer.simple_column :order
    importer.simple_column :redirect_link
    importer.simple_column :form_id do |row, item, head, value|
      item.form = value.present? ? node.st_forms.where(name: value).first : nil
    end
  end

  def define_importer_meta(importer)
    importer.simple_column :keywords
    importer.simple_column :description
    importer.simple_column :summary_html
  end

  def define_importer_body(importer)
    importer.simple_column :html
    importer.simple_column :body_parts do |row, item, head, value|
      item.body_parts = to_array(value, delim: "\t")
    end
  end

  def define_importer_category(importer)
    importer.simple_column :categories do |row, item, head, value|
      category_ids = category_name_tree_to_ids(to_array(value))
      categories = Category::Node::Base.site(site).in(id: category_ids)
      #if node.st_categories.present?
      #  filenames = node.st_categories.pluck(:filename)
      #  filenames += node.st_categories.map { |c| /^#{c.filename}\// }
      #  categories = categories.in(filename: filenames)
      #end
      item.category_ids = categories.pluck(:id)
    end
  end

  def define_importer_event_date(importer)
    importer.simple_column :event_name
    Event::MAX_RECURRENCES_TO_IMPORT_EXPORT.times do |index|
      column_name = "#{Cms::Page.t(:event_recurrences)}_#{index + 1}_開始日"
      importer.simple_column "event_recurrence_#{index}".to_sym, name: column_name do |row, item, head, value|
        import_event_recurrence(index, row, item, head, value)
      end
    end
    importer.simple_column :event_deadline
  end

  def define_importer_related_pages(importer)
    importer.simple_column :related_pages do |row, item, head, value|
      page_names = to_array(value)
      item.related_page_ids = Cms::Page.site(site).in(filename: page_names).pluck(:id)
    end
    column_name = "#{self.class.model.t(:related_pages)}#{self.class.model.t(:related_page_sort)}"
    importer.simple_column :related_page_sort, name: column_name do |row, item, head, value|
      item.related_page_sort = from_label(value, item.related_page_sort_options, item.related_page_sort_compat_options)
    end
  end

  def define_importer_parent_crumb(importer)
    importer.simple_column :parent_crumb_urls, name: self.class.model.t(:parent_crumb)
  end

  def define_importer_contact_page(importer)
    importer.simple_column :contact_state do |row, item, head, value|
      item.contact_state = from_label(value, item.contact_state_options)
    end
    importer.simple_column :contact_group do |row, item, head, value|
      item.contact_group = Cms::Group.where(name: value).first
    end
    importer.simple_column :contact_charge
    importer.simple_column :contact_tel
    importer.simple_column :contact_fax
    importer.simple_column :contact_email
    importer.simple_column :contact_link_url
    importer.simple_column :contact_link_name
  end

  def define_importer_released(importer)
    importer.simple_column :released_type do |row, item, head, value|
      released_type = from_label(value, item.released_type_options)
      item.released_type = released_type.presence
    end
    importer.simple_column :released
    importer.simple_column :release_date
    importer.simple_column :close_date
  end

  def define_importer_groups(importer)
    importer.simple_column :groups do |row, item, head, value|
      group_names = to_array(value)
      item.group_ids = SS::Group.in(name: group_names).pluck(:id)
    end
    importer.simple_column :permission_level
  end

  def define_importer_state(importer)
    importer.simple_column :state do |row, item, head, value|
      state = from_label(value, item.state_options, item.state_private_options)
      item.state = state.presence || "public"
    end
  end

  def define_importer_forms(importer)
    return if !node.respond_to?(:st_forms)

    node.st_forms.each do |form|
      # currently entry type form is not supported
      next if !form.sub_type_static?

      importer.form form.name do
        form.columns.each do |column|
          importer.column column.name do |row, item, _form, _column, values|
            import_column(row, item, form, column, values)
          end
        end
      end
    end
  end

  def import_column(_row, item, _form, column, values)
    column_value = item.column_values.where(column_id: column.id).first
    if column_value.blank?
      column_value = item.column_values.build(
        _type: column.value_type.name, column: column, name: column.name, order: column.order
      )
    end
    column_value.import_csv(values)
    column_value
  end

  def import_event_recurrence(index, row, item, head, start_on)
    return if start_on.blank?

    until_on = row["#{Cms::Page.t(:event_recurrences)}_#{index + 1}_終了日"].try(:strip).presence
    start_time = row["#{Cms::Page.t(:event_recurrences)}_#{index + 1}_開始時刻"].try(:strip).presence
    end_time = row["#{Cms::Page.t(:event_recurrences)}_#{index + 1}_終了時刻"].try(:strip).presence
    wdays = row["#{Cms::Page.t(:event_recurrences)}_#{index + 1}_曜日"].try(:strip).presence
    exclude_dates = row["#{Cms::Page.t(:event_recurrences)}_#{index + 1}_除外日"].try(:strip).presence

    wdays = to_array(wdays, delim: ",") if wdays
    exclude_dates = to_array(exclude_dates) if exclude_dates

    recurrence = {
      in_update_from_view: 1, in_start_on: start_on, in_until_on: until_on,
      in_start_time: start_time, in_end_time: end_time, in_by_days: wdays, in_exclude_dates: exclude_dates
    }

    recurrences = item.event_recurrences.try(:to_a)
    recurrences = recurrences ? recurrences.dup : []
    recurrences << recurrence
    item.event_recurrences = recurrences
  end

  def parse_wdays(wdays)
    wdays = wdays.to_s.split(",").map(&:strip).select(&:present?)
    abbr_day_names = I18n.t("date.abbr_day_names")

    wdays.map { |wday| abbr_day_names.find_index(abbr_day_names) }.compact
  end

  def parse_exclude_dates(dates)
    dates = dates.to_s.split(/\R/).map(&:strip).select(&:present?)
    dates.map(&:in_time_zone).select(&:present?).map(&:to_date)
  end
end