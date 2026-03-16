Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  namespace :api do
    post "auth/register" => "auth#register"
    post "auth/login" => "auth#login"
    get "auth/users" => "auth#users"
    patch "auth/users/:id/chat_ids" => "auth#update_chat_ids"
    get "me/chats" => "me#chats"
    get "me/chats/:chat_id" => "me#chat"
    get "me/chats/:chat_id/members" => "me#chat_members"
    get "me/search/messages" => "me#search_messages"

    namespace :telegram do
      resources :chats, only: %i[index], controller: "chats"
      resources :sessions, only: %i[index create show destroy], controller: "sessions" do
        member do
          post :phone
          post :code
          post :password
          get :watch_targets
          patch :watch_targets
          post :sync_chats
          post :sync_messages
          post :sync_group_members
        end
      end
    end
  end
end
