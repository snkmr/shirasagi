module Gws::Schedule::PlanFilter
  extend ActiveSupport::Concern

  included do
    prepend_view_path "app/views/gws/schedule/plans"
    navi_view "gws/schedule/main/navi"
    helper Gws::Schedule::PlanHelper
    model Gws::Schedule::Plan
  end

  private
    def set_crumbs
      @crumbs << [:"modules.gws_schedule", gws_schedule_plans_path]
    end

    def fix_params
      { cur_user: @cur_user, cur_site: @cur_site }
    end

    def pre_params
      { member_ids: [@cur_user.id] }
    end

  public
    def index
      render
    end
end
