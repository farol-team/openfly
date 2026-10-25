class HealthController < ActionController::API
  def live
    render json: {status: "ok", service: "openfly"}
  end

  def show
    ApplicationRecord.connection.select_value("SELECT 1")
    render json: {status: "ok", service: "openfly"}
  rescue StandardError
    render json: {status: "unavailable", service: "openfly"}, status: :service_unavailable
  end

  def ready
    checks = Pool::Readiness.new.call
    render json: checks, status: checks[:ready] ? :ok : :service_unavailable
  end
end
